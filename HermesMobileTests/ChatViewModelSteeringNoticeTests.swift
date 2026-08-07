import XCTest
@testable import HermesMobile

/// #183: the "Steering hint delivered." confirmation is transient feedback — one
/// card at a time, auto-dismissed, and never persisted into the transcript.
@MainActor
final class ChatViewModelSteeringNoticeTests: XCTestCase {
    private static let confirmation = "Steering hint delivered."

    override func setUp() {
        super.setUp()
        ChatViewModel.steeringNoticeDismissDelay = .milliseconds(40)
    }

    override func tearDown() {
        ChatViewModel.steeringNoticeDismissDelay = .seconds(3)
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSteeringConfirmationShowsOneCardAndAutoDismisses() async throws {
        let (viewModel, _) = try await makeStreamingViewModel()

        await steer(viewModel, "prefer tests")
        XCTAssertEqual(viewModel.pinnedLocalNotices, [Self.confirmation])

        // A second hint replaces the card rather than stacking a new one.
        await steer(viewModel, "and keep it short")
        XCTAssertEqual(viewModel.pinnedLocalNotices, [Self.confirmation])

        try await waitUntil { viewModel.pinnedLocalNotices.isEmpty }
        XCTAssertFalse(viewModel.messages.contains { $0.role == "local_notice" })
    }

    func testSteeringConfirmationIsDroppedWhenTheResponseEndsFirst() async throws {
        let (viewModel, streamClient) = try await makeStreamingViewModel()

        ChatViewModel.steeringNoticeDismissDelay = .seconds(30)
        await steer(viewModel, "prefer tests")
        XCTAssertEqual(viewModel.pinnedLocalNotices, [Self.confirmation])

        streamClient.emit(.streamEnd)

        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertFalse(viewModel.messages.contains { $0.role == "local_notice" })
    }

    func testOtherPinnedNoticesStillFlushIntoTheTranscript() async throws {
        let (viewModel, streamClient) = try await makeStreamingViewModel()

        viewModel.pinLocalNoticeMessage("Goal set.")
        await steer(viewModel, "prefer tests")
        XCTAssertEqual(viewModel.pinnedLocalNotices, ["Goal set.", Self.confirmation])

        streamClient.emit(.streamEnd)

        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == "local_notice" }.map(\.content),
            ["Goal set."]
        )
    }

    // MARK: - Helpers

    private func steer(_ viewModel: ChatViewModel, _ text: String) async {
        let command = try? XCTUnwrap(SlashCommandCatalog.command(named: "steer"))
        guard let command else { return }
        _ = await viewModel.executeSlashCommand(command, args: text)
    }

    private func makeStreamingViewModel() async throws -> (ChatViewModel, ScriptedSSEStreamingClient) {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/steer":
                return apiTestJSONResponse(#"{"accepted": true}"#, for: request)
            default:
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Steering", "messages": []}}"#,
                    for: request
                )
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(
                #"{"session_id": "session-abc", "title": "Steering", "workspace": "/tmp/workspace"}"#.utf8
            )
        )

        let streamClient = ScriptedSSEStreamingClient()
        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            streamingScrollCoalescingDelayNanoseconds: 1_000_000
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }

        let didSend = await viewModel.sendMessage("Start working")
        XCTAssertTrue(didSend)
        XCTAssertNotNil(viewModel.activeStreamID)

        return (viewModel, streamClient)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Condition was never met.")
    }
}
