import XCTest
@testable import HermesMobile

/// The call loop (#1091) against a fake voice session and a fake chat: what reaches the voice and
/// what reaches Hermes.
@MainActor final class HermesVoiceCallTests: XCTestCase {
    func testADelegationSendsTheLastWordsWithTheSpokenExchangeOnce() async {
        let (call, transport, chat, _) = await startedCall()
        XCTAssertEqual(call.status, .listening)

        await delegate(transport, chat)

        XCTAssertEqual(chat.submits.map(\.prompt), ["Check the build."])
        XCTAssertEqual(chat.submits.first?.context, "Voice assistant: How can I help?\nUser: Check the build.")
        XCTAssertEqual(call.status, .thinking)
    }

    func testAStreamingReplyIsSpokenASentenceAtATimeAndItsRestAtTheEnd() async {
        let (call, transport, chat, _) = await startedCall()
        await delegate(transport, chat)

        chat.emit(.reply("Two errors"))
        chat.emit(.reply(" found. Then"))
        XCTAssertEqual(transport.commentary, ["Two errors found."])
        chat.emit(.reply(" the fix"))
        XCTAssertEqual(transport.commentary, ["Two errors found."], "an unfinished sentence waits")

        chat.voiceTurnReply = "Two errors found. Then the fix"
        chat.emit(.settled(lostTrack: false))
        XCTAssertEqual(transport.commentary, ["Two errors found.", "Then the fix"])
        XCTAssertEqual(call.status, .listening)
    }

    func testATurnTheCallDidNotSendIsNotSpoken() async {
        let (_, transport, chat, _) = await startedCall()

        chat.emit(.reply("A typed question's answer. "))
        chat.emit(.toolStarted("terminal"))
        chat.voiceTurnReply = "A typed question's answer."
        chat.emit(.settled(lostTrack: false))

        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testEachNewToolIsOneQuietProgressNote() async {
        let (_, transport, chat, _) = await startedCall()
        await delegate(transport, chat)

        chat.emit(.toolStarted("terminal"))
        chat.emit(.toolStarted("terminal"))

        XCTAssertEqual(transport.thinking, ["Hermes is working: terminal. Not done yet."])
        XCTAssertTrue(transport.commentary.isEmpty)
    }

    func testANewerRequestWhileBusyStopsTheTurnThenGoesOutOnceIdle() async {
        let (_, transport, chat, _) = await startedCall()
        chat.isIdleForVoice = false
        chat.isRunningTurn = true
        let interrupted = expectation(description: "The running turn is stopped")
        chat.onInterrupt = { interrupted.fulfill() }

        transport.hear(.user, "Actually, check the docs.")
        transport.onEvent?(.delegation(id: "d1"))
        await fulfillment(of: [interrupted], timeout: 5)
        XCTAssertTrue(chat.submits.isEmpty, "nothing goes out while the turn runs")

        let submitted = expectation(description: "The request goes out")
        chat.onSubmit = { submitted.fulfill() }
        chat.isIdleForVoice = true
        chat.isRunningTurn = false
        chat.emit(.turnEnded)
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertEqual(chat.submits.map(\.prompt), ["Actually, check the docs."])
        XCTAssertEqual(chat.interrupts, 1)
    }

    func testARequestTheChatNeverGetsIdleForIsAnsweredWithTheFailureLine() async {
        let (call, transport, chat, scheduler) = await startedCall()
        chat.isIdleForVoice = false
        chat.isRunningTurn = true
        let interrupted = expectation(description: "The running turn is stopped")
        chat.onInterrupt = { interrupted.fulfill() }
        transport.hear(.user, "Check the docs.")
        transport.onEvent?(.delegation(id: "d1"))
        await fulfillment(of: [interrupted], timeout: 5)

        scheduler.advance(by: HermesVoiceCall.idleWait)

        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.unreachable])
        XCTAssertTrue(chat.submits.isEmpty)
        XCTAssertEqual(call.status, .listening)

        // The turn the Stop never ended still runs: the next request stops it again.
        let stoppedAgain = expectation(description: "The next request stops the turn again")
        chat.onInterrupt = { stoppedAgain.fulfill() }
        transport.hear(.user, "Try again.")
        transport.onEvent?(.delegation(id: "d2"))
        await fulfillment(of: [stoppedAgain], timeout: 5)
        XCTAssertEqual(chat.interrupts, 2)
    }

    /// A Stop the host refused doesn't leave every later request in the turn waiting on it.
    func testARefusedStopLetsTheNextRequestStopTheTurn() async {
        let (_, transport, chat, _) = await startedCall()
        chat.isIdleForVoice = false
        chat.isRunningTurn = true
        chat.interruptResult = false
        let refused = expectation(description: "The first Stop is refused")
        chat.onInterrupt = { refused.fulfill() }
        transport.hear(.user, "Check the docs.")
        transport.onEvent?(.delegation(id: "d1"))
        await fulfillment(of: [refused], timeout: 5)

        chat.interruptResult = true
        let stopped = expectation(description: "The next request stops the turn")
        chat.onInterrupt = { stopped.fulfill() }
        transport.hear(.user, "Check the docs, please.")
        transport.onEvent?(.delegation(id: "d2"))
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(chat.interrupts, 2)
    }

    func testARefusedRequestIsAnsweredWithTheFailureLine() async {
        let (call, transport, chat, _) = await startedCall()
        chat.submitResult = false

        await delegate(transport, chat)

        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.unreachable])
        XCTAssertEqual(call.status, .listening)
    }

    /// A Stop would deny the approval the running turn waits on, so a new request neither stops
    /// it nor goes out; the voice points back at the phone instead.
    func testARequestWhileAnApprovalWaitsIsNeitherStoppedNorSent() async {
        let (_, transport, chat, _) = await startedCall()
        chat.isIdleForVoice = false
        chat.isRunningTurn = true
        chat.turnAwaitsAnswer = true

        transport.hear(.user, "And also the docs.")
        transport.onEvent?(.delegation(id: "d2"))

        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.stillWaiting])
        XCTAssertEqual(chat.interrupts, 0)
        XCTAssertTrue(chat.submits.isEmpty)
    }

    /// End while the session opens closes it then, so the opening stops and the microphone goes
    /// at once rather than once the host answers.
    func testEndingWhileTheSessionOpensClosesItAtOnce() async {
        let transport = FakeTransport()
        transport.holdsStart = true
        let call = HermesVoiceCall(transport: transport, chat: FakeChat(), scheduler: ManualScheduler())
        let opening = expectation(description: "The session is opening")
        transport.onStartCalled = { opening.fulfill() }
        let start = Task { await call.start() }
        await fulfillment(of: [opening], timeout: 5)

        call.end()
        XCTAssertEqual(call.status, .ended(.hungUp))
        XCTAssertEqual(transport.closes, 1)
        transport.finishStart()
        await start.value

        XCTAssertEqual(transport.closes, 1)
    }

    /// The turn the Stop was meant for ended and another now waits on an approval: a Stop would
    /// deny it, so the request points back at the phone instead and is not sent later.
    func testARequestWhoseNextTurnWaitsOnAnApprovalIsNeitherStoppedNorSent() async {
        let (call, transport, chat, _) = await startedCall()
        chat.isIdleForVoice = false
        chat.isRunningTurn = true
        let interrupted = expectation(description: "The running turn is stopped")
        chat.onInterrupt = { interrupted.fulfill() }
        transport.hear(.user, "Check the docs.")
        transport.onEvent?(.delegation(id: "d1"))
        await fulfillment(of: [interrupted], timeout: 5)

        chat.turnAwaitsAnswer = true
        let pointed = expectation(description: "The voice points at the phone")
        transport.onSend = { if $0["type"].text == "session.commentary.append" { pointed.fulfill() } }
        chat.emit(.turnEnded)
        await fulfillment(of: [pointed], timeout: 5)

        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.stillWaiting])
        XCTAssertEqual(chat.interrupts, 1)
        XCTAssertEqual(call.status, .listening, "the request is dropped, not sent once the approval's turn ends")
    }

    func testTenQuietMinutesHangUp() async {
        let (call, transport, _, scheduler) = await startedCall()

        scheduler.advance(by: HermesVoiceCall.inactivityLimit)

        XCTAssertEqual(call.status, .ended(.inactive))
        XCTAssertEqual(transport.closes, 1)
    }

    /// The bar's waveform follows the call's sound and goes flat when the call ends, even if a
    /// last reading arrives after.
    func testTheWaveformLevelFollowsTheCallAndGoesFlatWhenItEnds() async {
        let (call, transport, _, _) = await startedCall()

        transport.onAudioLevel?(0.2)
        XCTAssertEqual(call.audioLevel, 0.2)

        call.end()
        transport.onAudioLevel?(0.3)
        XCTAssertEqual(call.audioLevel, 0)
    }

    /// An approval nobody answers doesn't keep a billed call on: ten quiet minutes after the turn
    /// started waiting, it hangs up.
    func testAnUnansweredApprovalStillHangsUpAfterTenQuietMinutes() async {
        let (call, transport, chat, scheduler) = await startedCall()
        await delegate(transport, chat)
        scheduler.advance(by: .seconds(9 * 60))

        chat.isIdleForVoice = false
        chat.isRunningTurn = true
        chat.turnAwaitsAnswer = true
        chat.emit(.awaitsAnswer)
        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.needsApproval])
        scheduler.advance(by: .seconds(60))
        XCTAssertFalse(call.isEnded, "the quiet minutes count from the approval")

        scheduler.advance(by: HermesVoiceCall.inactivityLimit)
        XCTAssertEqual(call.status, .ended(.inactive))
        XCTAssertEqual(transport.closes, 1)
    }

    /// A Hermes connection that doesn't come back within the grace gives the request up with the
    /// failure line, and then ten quiet minutes hang up; one that comes back keeps it.
    func testALostHermesConnectionGivesUpTheRequestAfterTheGrace() async {
        let (call, transport, chat, scheduler) = await startedCall()
        await delegate(transport, chat)

        chat.emit(.hermesLost)
        scheduler.advance(by: .seconds(60))
        chat.emit(.hermesRestored)
        scheduler.advance(by: HermesVoiceCall.hermesLostGrace)
        XCTAssertTrue(transport.commentary.isEmpty)
        XCTAssertEqual(call.status, .thinking)

        chat.emit(.hermesLost)
        scheduler.advance(by: HermesVoiceCall.hermesLostGrace)
        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.unreachable])
        XCTAssertEqual(call.status, .listening)
        chat.emit(.reply("A late reply. "))
        XCTAssertEqual(transport.commentary, [HermesVoiceCall.Line.unreachable], "a dropped request is not spoken")

        scheduler.advance(by: HermesVoiceCall.inactivityLimit)
        XCTAssertEqual(call.status, .ended(.inactive))
    }

    /// One call holds the audio process-wide. A new call tears down one still ending after End
    /// before it reads the audio session, and that call's late release can't clear the new hold.
    func testANewCallTakesTheAudioFromOneStillEnding() {
        let state = ComposerAudioCaptureState.shared
        let ending = NSObject(), next = NSObject()
        addTeardownBlock { @MainActor in state.releaseCall(ending); state.releaseCall(next) }
        var heldWhileReleasing: Bool?
        state.claimCall(ending) { heldWhileReleasing = state.isOnCall; state.releaseCall(ending) }
        XCTAssertTrue(state.isCapturing)

        state.claimCall(next) {}
        XCTAssertEqual(heldWhileReleasing, false, "the ending call let go before the new one took the audio")
        state.releaseCall(ending)
        XCTAssertTrue(state.isOnCall)

        state.releaseCall(next)
        XCTAssertFalse(state.isOnCall)
    }

    // MARK: Fixture

    /// The calls under test: the session's callbacks hold theirs weakly, as the chat will.
    private var calls: [HermesVoiceCall] = []

    private func startedCall() async -> (HermesVoiceCall, FakeTransport, FakeChat, ManualScheduler) {
        let transport = FakeTransport(), chat = FakeChat(), scheduler = ManualScheduler()
        let call = HermesVoiceCall(transport: transport, chat: chat, scheduler: scheduler)
        calls.append(call)
        await call.start()
        return (call, transport, chat, scheduler)
    }

    /// The voice asks Hermes to check the build, and the chat takes it.
    private func delegate(_ transport: FakeTransport, _ chat: FakeChat) async {
        let submitted = expectation(description: "The request goes out")
        chat.onSubmit = { submitted.fulfill() }
        transport.hear(.assistant, "How can I help?")
        transport.hear(.user, "Check the build.")
        transport.onEvent?(.delegation(id: "d1"))
        await fulfillment(of: [submitted], timeout: 5)
    }
}

@MainActor private final class FakeTransport: VoiceLiveTransport {
    var onEvent: ((VoiceLiveServerEvent) -> Void)?
    var onClosed: ((String) -> Void)?
    var onSpeakingChange: ((Bool) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    private(set) var sent: [BotJSON] = []
    private(set) var closes = 0
    var onSend: ((BotJSON) -> Void)?
    var holdsStart = false
    var onStartCalled: (() -> Void)?
    private var opening: CheckedContinuation<Void, Error>?
    private var clockMs: Double = 0

    var commentary: [String] { contents("session.commentary.append") }
    var thinking: [String] { contents("session.thinking.append") }

    func start(history: [BotJSON]) async throws {
        guard holdsStart else { return }
        try await withCheckedThrowingContinuation { opening = $0; onStartCalled?() }
    }

    func finishStart() { opening?.resume(); opening = nil }
    func send(_ event: BotJSON) { sent.append(event); onSend?(event) }
    func setMuted(_ muted: Bool) {}
    func close() { closes += 1 }

    /// One transcript fragment, a second after the last.
    func hear(_ speaker: VoiceLiveSpeaker, _ text: String) {
        clockMs += 1_000
        onEvent?(.transcript(VoiceLiveTranscriptFragment(speaker: speaker, text: text, startMs: clockMs - 900, endMs: clockMs)))
    }

    private func contents(_ type: String) -> [String] {
        sent.filter { $0["type"].text == type }.compactMap { $0["content"].text }
    }
}

@MainActor private final class FakeChat: VoiceCallChatPort {
    var isIdleForVoice = true
    var isRunningTurn = false
    var turnAwaitsAnswer = false
    var voiceTurnReply: String?
    var voiceHistory: [(speaker: VoiceLiveSpeaker, text: String)] = []
    var voiceTurnEvents: ((HermesVoiceTurnEvent) -> Void)?
    var submitResult = true
    var interruptResult = true
    var onSubmit: (() -> Void)?
    var onInterrupt: (() -> Void)?
    private(set) var submits: [(prompt: String, context: String)] = []
    private(set) var interrupts = 0

    func interruptForVoice() async -> Bool {
        interrupts += 1
        onInterrupt?()
        return interruptResult
    }

    func submitVoice(prompt: String, context: String) async -> Bool {
        submits.append((prompt, context))
        onSubmit?()
        return submitResult
    }

    func emit(_ event: HermesVoiceTurnEvent) { voiceTurnEvents?(event) }
}

/// Timers that fire only when the test moves the clock.
@MainActor private final class ManualScheduler: VoiceCallScheduling {
    private var now: Duration = .zero
    private var timers: [(id: Int, due: Duration, action: @MainActor () -> Void)] = []
    private var nextID = 0

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, now + delay, action))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(by delay: Duration) {
        now += delay
        let due = timers.filter { $0.due <= now }
        timers.removeAll { $0.due <= now }
        due.forEach { $0.action() }
    }
}
