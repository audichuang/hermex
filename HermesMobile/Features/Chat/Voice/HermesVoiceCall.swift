import Foundation
import Observation

/// The live voice session a call talks over (#1091): the WebRTC peer connection and its
/// `oai-events` data channel in the app, a fake in tests. The call numbers and builds every
/// client event (`VoiceLiveClientEvents`); the transport only carries them.
@MainActor protocol VoiceLiveTransport: AnyObject {
    /// A decoded server event. `session.closed` comes as `onClosed` instead.
    var onEvent: ((VoiceLiveServerEvent) -> Void)? { get set }
    /// The session is over and torn down: `close_requested` after `close()`, `connection_lost`,
    /// or the vendor's reason.
    var onClosed: ((String) -> Void)? { get set }
    /// The voice started or stopped producing audio.
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    /// How loud the call is right now (0...1): the voice or the unmuted microphone, whichever is
    /// louder. Zero once the session is torn down.
    var onAudioLevel: ((Double) -> Void)? { get set }
    /// Opens the microphone and the peer connection, and trades the offer for the host-minted
    /// session seeded with `history`.
    func start(history: [BotJSON]) async throws
    func send(_ event: BotJSON)
    /// Silences or restores the microphone track; the call sends the matching event itself.
    func setMuted(_ muted: Bool)
    /// Asks the session to close, then tears down; `onClosed` follows.
    func close()
}

/// What a voice call needs of its chat (`ChatViewModel`).
@MainActor protocol VoiceCallChatPort: AnyObject {
    /// No turn runs and no prompt is on its way: a delegation may go out.
    var isIdleForVoice: Bool { get }
    var isRunningTurn: Bool { get }
    /// A Stop now would withdraw a request only this user can still answer.
    var turnAwaitsAnswer: Bool { get }
    /// Stops the running turn; false when the host didn't take the Stop. Idle follows from the
    /// turn's own ending frames (`.turnEnded`).
    func interruptForVoice() async -> Bool
    /// Sends a delegation as a Send; true only when the host started its turn.
    func submitVoice(prompt: String, context: String) async -> Bool
    /// The just-ended turn's reply as the chat shows it.
    var voiceTurnReply: String? { get }
    /// The chat's text turns, oldest first, to seed the voice with.
    var voiceHistory: [(speaker: VoiceLiveSpeaker, text: String)] { get }
    /// Hears the claimed turn and every turn's end (`HermesChatTurnCoordinator.voiceTurnObserver`).
    var voiceTurnEvents: ((HermesVoiceTurnEvent) -> Void)? { get set }
}

/// Runs the call's timeouts; tests fire them by hand. Returns the cancel.
@MainActor protocol VoiceCallScheduling {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

struct VoiceCallTaskScheduler: VoiceCallScheduling {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

/// One GPT-Live voice call on a Hermes chat (#1091), Hermes Desktop's conversation loop: the voice
/// model talks with the user and hands real work to Hermes as a delegation, which goes out as an
/// ordinary turn on the chat once it is idle; that turn's reply streams back into the voice a
/// finished sentence at a time, its tools as quiet progress, and a request it waits on as a
/// pointer to the phone screen.
@MainActor @Observable final class HermesVoiceCall {
    enum Status: Equatable {
        case connecting, listening, thinking, speaking
        case ended(EndReason)
    }

    enum EndReason: Equatable {
        /// The user ended it.
        case hungUp
        /// Ten minutes without speech or a delegation.
        case inactive
        /// It never started: the host's or the device's reason.
        case failed(String)
        /// The session closed on its own: `connection_lost` or the vendor's reason, and how long
        /// the call had been up ("connection_lost, 28s"), shown as is to tell drops apart.
        case closed(String)
        /// The host replaced the Bot Chat the call talked on.
        case chatReplaced
    }

    struct Caption: Equatable {
        let speaker: VoiceLiveSpeaker
        var text: String
    }

    /// Sent to the voice as written: the voice model words them for the user, so they are not localized.
    enum Line {
        static let unreachable = "Sorry, I could not reach Hermes for that request."
        static let noSpokenResult = "Hermes finished that request without a spoken result."
        static let resultInChat = "Hermes finished; the result is in the chat."
        static let needsApproval = "Hermes needs your approval on the phone screen."
        static let stillWaiting = "That request is still waiting for your approval on the phone screen."
        static func working(_ tool: String) -> String { "Hermes is working: \(tool). Not done yet." }
    }

    static let idleWait: Duration = .seconds(10)
    static let inactivityLimit: Duration = .seconds(10 * 60)
    /// How long a delegation out waits for the lost Hermes connection to come back.
    static let hermesLostGrace: Duration = .seconds(2 * 60)

    private(set) var status: Status = .connecting
    private(set) var isMuted = false
    /// The latest stretch of speech, the user's or the voice's.
    private(set) var caption: Caption?
    /// The transport's `onAudioLevel`, for the call bar's waveform. Only the bar reads it.
    private(set) var audioLevel = 0.0

    var isEnded: Bool { if case .ended = status { return true }; return false }

    /// Called once, as the call ends by any path: End, the session closing, a failed start.
    @ObservationIgnored var onEnded: (@MainActor () -> Void)?

    @ObservationIgnored private let transport: any VoiceLiveTransport
    @ObservationIgnored private weak var chat: (any VoiceCallChatPort)?
    @ObservationIgnored private let scheduler: any VoiceCallScheduling
    @ObservationIgnored private var events = VoiceLiveClientEvents()
    @ObservationIgnored private var transcript = VoiceLiveTranscript()
    @ObservationIgnored private var delegation: Delegation?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var isLive = false
    @ObservationIgnored private var liveSince: ContinuousClock.Instant?
    @ObservationIgnored private var isSpeaking = false
    /// A Stop went out for the running turn; the next turn end clears it.
    @ObservationIgnored private var interruptSent = false
    @ObservationIgnored private var cancelInactivity: (@MainActor () -> Void)?
    @ObservationIgnored private var cancelHermesLostGrace: (@MainActor () -> Void)?

    /// One delegation, from the voice's request to its turn's end.
    private struct Delegation {
        enum Phase { case waiting, submitting, running }
        let id: String
        let prompt: String
        let context: String
        var phase = Phase.waiting
        var cancelIdleWait: (@MainActor () -> Void)?
        /// The claimed turn's reply as the chat builds it.
        var reply = ""
        var cursor = VoiceLiveSpeechCursor()
        var lastTool: String?
    }

    init(transport: any VoiceLiveTransport, chat: any VoiceCallChatPort,
         scheduler: (any VoiceCallScheduling)? = nil) {
        self.transport = transport
        self.chat = chat
        self.scheduler = scheduler ?? VoiceCallTaskScheduler()
    }

    // MARK: Lifecycle

    /// Opens the session once. An End while it opens closes the transport at once, which stops
    /// the opening.
    func start() async {
        guard !didStart, !isEnded else { return }
        didStart = true
        transport.onEvent = { [weak self] in self?.receive($0) }
        transport.onClosed = { [weak self] in self?.transportDidClose($0) }
        transport.onSpeakingChange = { [weak self] in self?.speakingDidChange($0) }
        transport.onAudioLevel = { [weak self] level in
            guard let self, !self.isEnded || level == 0, level != self.audioLevel else { return }
            self.audioLevel = level
        }
        chat?.voiceTurnEvents = { [weak self] in self?.receiveTurn($0) }
        do {
            try await transport.start(history: VoiceLiveProtocol.liveHistory(chat?.voiceHistory ?? []))
        } catch {
            finish(.failed(error.localizedDescription), closesTransport: true)
            return
        }
        // Ended while the session opened: `finish` closed the transport then.
        guard !isEnded else { return }
        isLive = true
        liveSince = .now
        armInactivity()
        refreshStatus()
    }

    /// Hangs up; `reason` says why when it isn't the user.
    func end(_ reason: EndReason = .hungUp) { finish(reason, closesTransport: true) }

    func setMuted(_ muted: Bool) {
        guard isLive, !isEnded, muted != isMuted else { return }
        isMuted = muted
        transport.setMuted(muted)
        transport.send(events.inputAudio(muted: muted))
    }

    private func finish(_ reason: EndReason, closesTransport: Bool) {
        guard !isEnded else { return }
        status = .ended(reason)
        audioLevel = 0
        isLive = false
        cancelInactivity?(); cancelInactivity = nil
        cancelHermesLostGrace?(); cancelHermesLostGrace = nil
        delegation?.cancelIdleWait?(); delegation = nil
        chat?.voiceTurnEvents = nil
        // A session still opening stops opening and releases the microphone at once.
        if closesTransport { transport.close() }
        let ended = onEnded
        onEnded = nil
        ended?()
    }

    private func transportDidClose(_ reason: String) {
        guard reason != "close_requested" else { return finish(.hungUp, closesTransport: false) }
        let seconds = liveSince.map { Int(($0.duration(to: .now)).components.seconds) }
        finish(.closed(seconds.map { "\(reason), \($0)s" } ?? reason), closesTransport: false)
    }

    private func speakingDidChange(_ speaking: Bool) {
        isSpeaking = speaking
        refreshStatus()
    }

    private func refreshStatus() {
        guard isLive, !isEnded else { return }
        let next: Status = isSpeaking ? .speaking : delegation != nil ? .thinking : .listening
        if next != status { status = next }
    }

    /// Hangs up after ten quiet minutes, never while a delegation is out, unless its turn has
    /// waited on an approval or a question that whole time.
    private func armInactivity() {
        cancelInactivity?()
        cancelInactivity = scheduler.schedule(after: Self.inactivityLimit) { [weak self] in
            guard let self, !self.isEnded else { return }
            if self.delegation != nil, self.chat?.turnAwaitsAnswer != true {
                self.armInactivity()
            } else {
                self.finish(.inactive, closesTransport: true)
            }
        }
    }

    // MARK: Voice events

    private func receive(_ event: VoiceLiveServerEvent) {
        guard !isEnded else { return }
        switch event {
        case .transcript(let fragment):
            transcript.append(fragment)
            showCaption(fragment)
            armInactivity()
        case .delegation(let id):
            armInactivity()
            delegate(id)
        case .started, .error, .closed:
            break
        }
    }

    private func showCaption(_ fragment: VoiceLiveTranscriptFragment) {
        guard !fragment.text.isEmpty else { return }
        if var shown = caption, shown.speaker == fragment.speaker {
            shown.text = String((shown.text + fragment.text).suffix(240))
            caption = shown
        } else {
            caption = Caption(speaker: fragment.speaker, text: fragment.text.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A newer request replaces the one in flight. One that would make a Stop deny a waiting
    /// approval only points back at the phone.
    private func delegate(_ id: String) {
        guard let chat else { return }
        if chat.turnAwaitsAnswer {
            speak(Line.stillWaiting, delegationID: id)
            return
        }
        let (prompt, context) = VoiceLiveProtocol.delegationPrompt(transcript.contextWindow)
        delegation?.cancelIdleWait?()
        var next = Delegation(id: id, prompt: prompt, context: context)
        next.cancelIdleWait = scheduler.schedule(after: Self.idleWait) { [weak self] in self?.idleWaitDidExpire(id) }
        delegation = next
        refreshStatus()
        advance()
    }

    private func idleWaitDidExpire(_ id: String) {
        guard delegation?.id == id, delegation?.phase == .waiting else { return }
        // A Stop that never ended the turn doesn't hold back the next request's.
        interruptSent = false
        drop(id, saying: Line.unreachable)
    }

    /// Gives up on a delegation, says why, and lets the quiet-minutes limit run again.
    private func drop(_ id: String, saying line: String) {
        delegation?.cancelIdleWait?()
        delegation = nil
        speak(line, delegationID: id)
        refreshStatus()
        armInactivity()
    }

    /// Moves a waiting delegation on, after the frame being applied: it goes out once the chat is
    /// idle, and the running turn is stopped once.
    private func advance() {
        Task { [weak self] in await self?.step() }
    }

    /// The running turn may have changed since the request came in, so a Stop is checked against
    /// a waiting approval again here. A Stop the host refused is not retried for this request.
    private func step() async {
        guard !isEnded, let chat, let waiting = delegation, waiting.phase == .waiting else { return }
        if chat.isIdleForVoice { return await submit(waiting) }
        guard chat.isRunningTurn, !interruptSent else { return }
        if chat.turnAwaitsAnswer { return drop(waiting.id, saying: Line.stillWaiting) }
        interruptSent = true
        guard await chat.interruptForVoice() else {
            interruptSent = false
            return
        }
        advance()
    }

    private func submit(_ sending: Delegation) async {
        delegation?.phase = .submitting
        delegation?.cancelIdleWait?(); delegation?.cancelIdleWait = nil
        let started = await chat?.submitVoice(prompt: sending.prompt, context: sending.context) ?? false
        // Superseded, ended or already settled meanwhile.
        guard !isEnded, delegation?.id == sending.id else { return advance() }
        if started {
            delegation?.phase = .running
        } else {
            drop(sending.id, saying: Line.unreachable)
        }
        advance()
    }

    // MARK: Turn events

    private func receiveTurn(_ event: HermesVoiceTurnEvent) {
        guard !isEnded else { return }
        switch event {
        case .turnEnded:
            interruptSent = false
            return advance()
        case .hermesLost:
            return armHermesLostGrace()
        case .hermesRestored:
            cancelHermesLostGrace?(); cancelHermesLostGrace = nil
            return
        default:
            break
        }
        // A turn the call did not send, or one a newer request replaced, is not spoken.
        guard var current = delegation, current.phase != .waiting else { return }
        switch event {
        case .reply(let text):
            current.reply += text
            delegation = current
            speakFinishedSentences()
        case .interim(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let separator = current.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            current.reply += separator + text
            delegation = current
            speakFinishedSentences()
        case .replyRebuilt(let reply):
            current.reply = reply
            delegation = current
            speakFinishedSentences()
        case .toolStarted(let tool):
            guard tool != current.lastTool else { return }
            current.lastTool = tool
            delegation = current
            think(Line.working(tool), delegationID: current.id)
        case .awaitsAnswer:
            speak(Line.needsApproval, delegationID: current.id)
            // The quiet minutes count from here: an unanswered request doesn't keep the call billed.
            armInactivity()
        case .settled(let lostTrack):
            settle(current, lostTrack: lostTrack)
        case .turnEnded, .hermesLost, .hermesRestored:
            break
        }
    }

    /// The chat lost its Hermes connection. A delegation still out when it hasn't come back
    /// within the grace is given up, so the quiet-minutes limit can end a call whose host is gone.
    private func armHermesLostGrace() {
        guard cancelHermesLostGrace == nil else { return }
        cancelHermesLostGrace = scheduler.schedule(after: Self.hermesLostGrace) { [weak self] in
            guard let self, !self.isEnded else { return }
            self.cancelHermesLostGrace = nil
            guard let current = self.delegation else { return }
            self.drop(current.id, saying: Line.unreachable)
        }
    }

    /// Speaks the streaming reply's next finished sentences.
    private func speakFinishedSentences() {
        guard var current = delegation else { return }
        let piece = current.cursor.advance(reply: current.reply, finished: false)
        delegation = current
        if let piece { speak(piece, delegationID: current.id) }
    }

    /// The turn ended: the reply's unspoken rest from what the chat shows, unless what was spoken
    /// no longer starts it.
    private func settle(_ current: Delegation, lostTrack: Bool) {
        if lostTrack {
            speak(Line.resultInChat, delegationID: current.id)
        } else {
            var cursor = current.cursor
            if let rest = cursor.advance(reply: chat?.voiceTurnReply ?? current.reply, finished: true) {
                speak(rest, delegationID: current.id)
            } else if cursor.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                think(Line.noSpokenResult, delegationID: current.id)
            }
        }
        delegation = nil
        refreshStatus()
        armInactivity()
    }

    private func speak(_ text: String, delegationID: String) {
        guard !isEnded else { return }
        for event in events.commentary(text, delegationID: delegationID) { transport.send(event) }
    }

    private func think(_ text: String, delegationID: String) {
        guard !isEnded, let event = events.thinking(text, delegationID: delegationID) else { return }
        transport.send(event)
    }
}
