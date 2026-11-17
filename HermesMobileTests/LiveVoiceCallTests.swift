import XCTest
@testable import HermesMobile

/// The app's one voice call (#1091): it belongs to the app, not to the screen it started on.
@MainActor final class LiveVoiceCallTests: XCTestCase {
    /// A call outlives every view of its chat: the owner keeps the chat's model and its stream
    /// until the call ends, then lets the model go and the stream suspends.
    func testACallKeepsItsChatAfterItsViewLeavesUntilItEnds() async throws {
        let owner = LiveVoiceCall()
        var chat: Chat? = await openChat(owner: owner)
        let transport = FakeTransport()
        chat?.model.makeVoiceLiveTransport = { _ in transport }
        let started = try XCTUnwrap(chat?.model.startVoiceCall())
        await started.value
        // The chat's last view leaves.
        chat?.model.suspendStreamForNavigation()
        weak let model = chat?.model
        let turn = try XCTUnwrap(chat?.turn)
        chat = nil

        XCTAssertNotNil(model, "the owner holds the chat while its call is on")
        XCTAssertTrue(turn.engine.isActive, "the call still hears the chat's stream")
        XCTAssertEqual(transport.closes, 0)
        XCTAssertNotNil(owner.call)

        owner.call?.end()
        XCTAssertNil(owner.call)
        XCTAssertNil(model, "an ended call lets its chat go")
        XCTAssertFalse(turn.engine.isActive, "the stream suspends once nothing shows the chat")
        XCTAssertEqual(transport.closes, 1)
    }

    /// The call belongs to its server: switching to another server or signing out ends it, and
    /// a sign-in that stays on its server keeps it.
    func testSwitchingServerOrSigningOutEndsTheCall() async throws {
        let owner = LiveVoiceCall()
        let chat = await openChat(owner: owner)
        let transport = FakeTransport()
        chat.model.makeVoiceLiveTransport = { _ in transport }
        let started = try XCTUnwrap(chat.model.startVoiceCall())
        await started.value

        owner.endUnless(server: Self.server)
        owner.endUnless(connectionID: Self.connection.id, on: Self.server)
        XCTAssertNotNil(owner.call, "the same server keeps its call")

        owner.endUnless(server: URL(string: "https://other.example")!)
        XCTAssertNil(owner.call)
        XCTAssertEqual(chat.model.voiceCall?.status, .ended(.hungUp))
        XCTAssertEqual(transport.closes, 1)

        let next = try XCTUnwrap(chat.model.startVoiceCall())
        await next.value
        owner.endUnless(server: nil)
        XCTAssertNil(owner.call, "signing out ends it")

        let third = try XCTUnwrap(chat.model.startVoiceCall())
        await third.value
        owner.endUnless(connectionID: UUID(), on: Self.server)
        XCTAssertNil(owner.call, "a replaced saved connection ends it")
    }

    // MARK: Fixture

    private static let server = URL(string: "https://hermes.example")!
    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
    }

    /// A Hermes chat attached to idle session `key`, whose call `owner` holds.
    private func openChat(owner: LiveVoiceCall, key: String = "tip", profile: String = "default",
                          target: ConversationTarget? = nil, lineageRoot: String? = nil) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("subagent.list", .init(result: .object(["subagents": .array([]), "delegations": .array([])])))
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string(key), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string(profile)])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        host.always("session.create", .init(result: .object([
            "session_id": .string("runtime"), "stored_session_id": .string(key), "message_count": .number(0),
            "messages": .array([]), "info": .object(["profile_name": .string(profile)])
        ])))
        let client = BotClient(http: host.connection(Self.connection))
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/sessions/\(key)/messages" else { return nil }
            return .json(200, .object(["session_id": .string(key), "messages": .array([])]))
        }
        let engine = HermesConversation(server: Self.server, connection: Self.connection,
                                        target: target ?? .session(profile: profile, key: key), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, botChatRoot: nil, lineageRoot: lineageRoot,
                                             isNetworkAvailable: { true }, ratingPromptState: isolatedRatingState())
        let model = ChatViewModel(
            session: SessionSummary(profile: profile), server: Self.server,
            liveActivityManager: QuietLiveActivity(), streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: MemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        model.liveCall = owner
        model.hermesLineageRoot = lineageRoot
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, turn: turn)
    }

    private func isolatedRatingState() -> RatingPromptState {
        let suite = "LiveVoiceCallTests.rating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return RatingPromptState(defaults: defaults)
    }
}

/// A call's session that opens at once and counts its closes.
@MainActor private final class FakeTransport: VoiceLiveTransport {
    var onEvent: ((VoiceLiveServerEvent) -> Void)?
    var onClosed: ((String) -> Void)?
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var closes = 0

    func start(history: [BotJSON]) async throws {}
    func send(_ event: BotJSON) {}
    func setMuted(_ muted: Bool) {}
    func close() { closes += 1 }
}

private final class QuietLiveActivity: AgentLiveActivityManaging {
    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

private actor MemoryDrafts: ChatDraftPersisting {
    private var values: [ChatDraftKey: ChatDraft] = [:]
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
}
