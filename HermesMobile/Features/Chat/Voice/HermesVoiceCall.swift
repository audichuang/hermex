import Foundation
import Observation
import OSLog

/// How a live session's peer connection is doing, between `start` and the end.
enum VoiceLiveConnectionChange: Equatable {
    /// WebRTC lost touch with the vendor (`disconnected`); it may come back on its own.
    case unstable
    /// An unstable connection came back.
    case restored
    /// The peer connection is gone (`failed`, or its data channel closed). The microphone and
    /// audio session stay until the call reconnects or closes.
    case lost
}

/// The live voice session a call talks over (#1091): the WebRTC peer connection and its
/// `oai-events` data channel in the app, a fake in tests. The call numbers and builds every
/// client event (`VoiceLiveClientEvents`); the transport only carries them.
@MainActor protocol VoiceLiveTransport: AnyObject {
    /// A decoded server event. `session.closed` comes as `onClosed` instead.
    var onEvent: ((VoiceLiveServerEvent) -> Void)? { get set }
    /// The session is over and torn down: `close_requested` after `close()`, `interrupted`,
    /// `replaced`, or the vendor's reason.
    var onClosed: ((String) -> Void)? { get set }
    /// The peer connection wavered, came back or dropped.
    var onConnection: ((VoiceLiveConnectionChange) -> Void)? { get set }
    /// The voice started or stopped producing audio.
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    /// How loud the call is right now (0...1): the voice or the unmuted microphone, whichever is
    /// louder. Zero once the session is torn down.
    var onAudioLevel: ((Double) -> Void)? { get set }
    /// Opens the microphone and the peer connection, and trades the offer for the host-minted
    /// session seeded with `history`.
    func start(history: [BotJSON]) async throws
    /// Drops the peer connection and opens a fresh session seeded with `history`, keeping the
    /// microphone; returns once it connects.
    func reconnect(history: [BotJSON]) async throws
    /// Gives up on the reconnect in flight, which then throws.
    func cancelReconnect()
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
    /// Mints a GPT-Live session in the chat's Profile on its connection.
    func voiceLiveSession(sdp: String, history: [BotJSON]) async throws -> HermesVoiceLiveSession
    /// The just-ended turn's reply as the chat shows it.
    var voiceTurnReply: String? { get }
    /// The chat's text turns, oldest first, to seed the voice with.
    var voiceHistory: [(speaker: VoiceLiveSpeaker, text: String)] { get }
    /// Hears the claimed turn and every turn's end (`HermesChatTurnCoordinator.voiceTurnObserver`).
    var voiceTurnEvents: ((HermesVoiceTurnEvent) -> Void)? { get set }
}

/// Call lifecycle lines for diagnosing drops on a device: connection changes and redial
/// outcomes, by count only.
enum VoiceCallLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "VoiceCall")
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
        /// The connection wavered or dropped; the call is waiting for it or dialing again.
        case reconnecting
        case ended(EndReason)
    }

    enum EndReason: Equatable {
        /// The user ended it.
        case hungUp
        /// Ten minutes without speech or a delegation.
        case inactive
        /// It never started: the host's or the device's reason.
        case failed(String)
        /// The session closed on its own: `connection_lost` once reconnecting gave up, or the
        /// vendor's reason, and how long the call had been up ("connection_lost, 28s"), shown as
        /// is to tell drops apart.
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
        static let movedChat = "The user opened another chat. That request goes on in the previous chat, and its result will be there."
        static func working(_ tool: String) -> String { "Hermes is working: \(tool). Not done yet." }
        static let queued = "Hermes is still working on the previous request. This one goes next, once it finishes."
        static let stopped = "Okay, Hermes stopped that request."
        static let stopRefused = "Hermes did not take the stop; that request may still be running."
    }

    static let idleWait: Duration = .seconds(10)
    static let inactivityLimit: Duration = .seconds(10 * 60)
    /// How long a delegation out waits for the lost Hermes connection to come back.
    static let hermesLostGrace: Duration = .seconds(2 * 60)
    /// How long a wavering connection gets to come back on its own before the call dials again.
    static let unstableGrace: Duration = .seconds(6)
    /// How long one redial gets to connect.
    static let redialTimeout: Duration = .seconds(15)
    /// The waits before each redial after the first, which goes at once; the last repeats.
    static let redialBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    /// How long the call keeps dialing before it gives up. A phone with no signal fails each
    /// try fast, so the window, not a count, bounds those.
    static let reconnectWindow: Duration = .seconds(60)
    /// Sessions the host may mint for redials, each one billed, until the call has stayed up
    /// for `stableAfter`.
    static let redialSessionLimit = 4
    /// How long a reconnected call stays up before a later drop gets every redial again.
    static let stableAfter: Duration = .seconds(60)
    /// How long after the user's last words their utterance counts as finished, for a spoken stop.
    static let utteranceSettle: Duration = .milliseconds(1_500)
    /// Added to a sentence's estimated speaking time before it counts as heard: a drop is noticed
    /// seconds after the audio stopped, so a sentence near the drop is said again rather than lost.
    static let heardSlack: Duration = .seconds(3)
    /// How often one request's unheard speech is said again after drops.
    static let maxReplays = 2
    /// The most a queued request's merged words hold, newest kept.
    static let maxQueuedPrompt = 2_000

    private(set) var status: Status = .connecting
    private(set) var isMuted = false
    /// The latest stretch of speech, the user's or the voice's.
    private(set) var caption: Caption?
    /// The transport's `onAudioLevel`, for the call bar's waveform. Only the bar reads it.
    private(set) var audioLevel = 0.0
    /// When the session came up, for the call bar's timer.
    private(set) var connectedAt: Date?
    /// Called once, when the session is up: the connected cue.
    @ObservationIgnored var onLive: (@MainActor () -> Void)?
    /// True as the call starts reconnecting, false once it is back: the reconnecting cue.
    @ObservationIgnored var onReconnecting: (@MainActor (Bool) -> Void)?

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
    /// The connection wavered or dropped and isn't back: speech waits in `heldSpeech`.
    @ObservationIgnored private var isReconnecting = false
    @ObservationIgnored private var cancelUnstableGrace: (@MainActor () -> Void)?
    /// The redial in flight, by number; a late answer to an older one is ignored.
    @ObservationIgnored private var redialAttempt: Int?
    @ObservationIgnored private var redialSerial = 0
    /// Tries since the connection last went down, for the backoff.
    @ObservationIgnored private var redialsThisDrop = 0
    /// Sessions minted for redials since the call was last stable.
    @ObservationIgnored private var redialSessions = 0
    @ObservationIgnored private var cancelRedialTimer: (@MainActor () -> Void)?
    @ObservationIgnored private var cancelReconnectWindow: (@MainActor () -> Void)?
    @ObservationIgnored private var cancelStableTimer: (@MainActor () -> Void)?
    /// Whether the session the voice talks on was last told the microphone is muted.
    @ObservationIgnored private var sessionMuted = false
    /// What the voice should say or note, kept while the connection is down and sent once it is back.
    @ObservationIgnored private var heldSpeech: [(utterance: Utterance, delegationID: String)] = []
    /// The delegations the current session started. A redial's session never heard of the
    /// earlier ones, so speech about them goes out without their id.
    @ObservationIgnored private var sessionDelegations: Set<String> = []
    /// A request that waits for the call's running turn to finish instead of stopping its work.
    @ObservationIgnored private var queued: Delegation?
    /// A delegation the user stopped while its Send was on the way: its turn is stopped once it starts.
    @ObservationIgnored private var stoppedWhileSubmitting: String?
    /// The user's words since their utterance last settled, for a spoken stop.
    @ObservationIgnored private var userUtterance = ""
    @ObservationIgnored private var cancelUtteranceSettle: (@MainActor () -> Void)?
    /// Speech sent to the session that may not have been heard yet, oldest first.
    @ObservationIgnored private var unheard: [Spoken] = []
    /// What was still unheard when the connection went down: said again on a redialed session.
    @ObservationIgnored private var unheardAtDrop: [Spoken] = []
    @ObservationIgnored private var spokenSerial = 0
    @ObservationIgnored private var replays: [String: Int] = [:]

    private enum Utterance { case say(String), think(String) }

    private struct Spoken {
        let serial: Int
        let text: String
        let delegationID: String
        let duration: Duration
    }

    /// One delegation, from the voice's request to its turn's end.
    private struct Delegation {
        enum Phase { case waiting, submitting, running }
        let id: String
        var prompt: String
        let context: String
        /// A queued request goes out after the running turn instead of stopping it.
        var mayStopTurn = true
        var phase = Phase.waiting
        let createdAt = ContinuousClock.now
        var heardFirstReply = false
        var spokeFirst = false
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
        transport.onConnection = { [weak self] in self?.connectionDidChange($0) }
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
        connectedAt = Date()
        armInactivity()
        refreshStatus()
        let live = onLive
        onLive = nil
        live?()
    }

    /// The call now talks on `next`, the chat the user opened, as Hermes Desktop's call follows
    /// its window's open chat: a delegation not yet sent, and every later one, goes there. One
    /// already sent stays with the chat it went to and is no longer spoken; the voice hears where
    /// its result will be. The session is not seeded again: the voice keeps what it heard.
    func move(to next: any VoiceCallChatPort) {
        guard !isEnded, next !== chat else { return }
        chat?.voiceTurnEvents = nil
        if let current = delegation, current.phase != .waiting {
            delegation = nil
            think(Line.movedChat, delegationID: current.id)
        }
        interruptSent = false
        stoppedWhileSubmitting = nil
        cancelHermesLostGrace?(); cancelHermesLostGrace = nil
        chat = next
        if didStart { next.voiceTurnEvents = { [weak self] in self?.receiveTurn($0) } }
        // A queued request was never sent: it goes to the chat the user opened, like any other.
        if delegation == nil { promoteQueued(mayStopTurn: true) }
        guard isLive else { return }
        refreshStatus()
        armInactivity()
        if delegation != nil { advance() }
    }

    /// Hangs up; `reason` says why when it isn't the user.
    func end(_ reason: EndReason = .hungUp) { finish(reason, closesTransport: true) }

    func setMuted(_ muted: Bool) {
        guard isLive, !isEnded, muted != isMuted else { return }
        isMuted = muted
        transport.setMuted(muted)
        // A wavering or redialed session hears it once it is back.
        if !isReconnecting { syncMute() }
    }

    private func syncMute() {
        guard isMuted != sessionMuted else { return }
        sessionMuted = isMuted
        transport.send(events.inputAudio(muted: isMuted))
    }

    /// A redial's session, minted on the chat the call talks on now (`makeVoiceCall`).
    func openSession(sdp: String, history: [BotJSON]) async throws -> HermesVoiceLiveSession {
        guard !isEnded, let chat else { throw BotFailure.stale }
        let session = try await chat.voiceLiveSession(sdp: sdp, history: history)
        if isReconnecting { redialSessions += 1 }
        return session
    }

    private func finish(_ reason: EndReason, closesTransport: Bool) {
        guard !isEnded else { return }
        status = .ended(reason)
        audioLevel = 0
        onLive = nil
        isLive = false
        cancelInactivity?(); cancelInactivity = nil
        cancelHermesLostGrace?(); cancelHermesLostGrace = nil
        cancelUnstableGrace?(); cancelUnstableGrace = nil
        cancelRedialTimer?(); cancelRedialTimer = nil
        cancelReconnectWindow?(); cancelReconnectWindow = nil
        cancelStableTimer?(); cancelStableTimer = nil
        redialAttempt = nil
        heldSpeech = []
        unheard = []
        unheardAtDrop = []
        queued = nil
        cancelUtteranceSettle?(); cancelUtteranceSettle = nil
        // No connected cue for a call that ends while it reconnects: `onEnded` stops the tones.
        isReconnecting = false
        onReconnecting = nil
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
        let next: Status = isReconnecting ? .reconnecting : isSpeaking ? .speaking : delegation != nil ? .thinking : .listening
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

    // MARK: Reconnecting

    /// Like a phone call on a weak signal: a wavering connection gets a few seconds to come back
    /// on its own, then the call dials a fresh session, seeded with the chat and what was said on
    /// the call, a bounded number of times before it gives up. Delegations and their turns carry
    /// on meanwhile; what the voice should say waits until it can hear it.
    private func connectionDidChange(_ change: VoiceLiveConnectionChange) {
        guard isLive, !isEnded, redialAttempt == nil else { return }
        VoiceCallLog.logger.notice("Connection \(String(describing: change), privacy: .public)")
        switch change {
        case .unstable:
            guard cancelUnstableGrace == nil else { return }
            setReconnecting(true)
            cancelUnstableGrace = scheduler.schedule(after: Self.unstableGrace) { [weak self] in
                guard let self, !self.isEnded else { return }
                self.cancelUnstableGrace = nil
                self.redial()
            }
        case .restored:
            cancelUnstableGrace?(); cancelUnstableGrace = nil
            setReconnecting(false)
        case .lost:
            cancelUnstableGrace?(); cancelUnstableGrace = nil
            setReconnecting(true)
            redial()
        }
    }

    private func setReconnecting(_ reconnecting: Bool) {
        guard reconnecting != isReconnecting else { return }
        isReconnecting = reconnecting
        cancelStableTimer?(); cancelStableTimer = nil
        if reconnecting {
            redialsThisDrop = 0
            // Frozen at the drop: what the voice may not have said yet is said again on a redial.
            unheardAtDrop = unheard
            unheard = []
            cancelReconnectWindow = scheduler.schedule(after: Self.reconnectWindow) { [weak self] in
                self?.cancelReconnectWindow = nil
                self?.giveUpReconnecting()
            }
        } else {
            cancelReconnectWindow?(); cancelReconnectWindow = nil
            // The same session came back and still has what it was sent.
            unheardAtDrop = []
            syncMute()
            let held = heldSpeech
            heldSpeech = []
            for (utterance, id) in held { send(utterance, delegationID: id) }
            // Only a call that stays up earns its redial sessions back, so a session that keeps
            // dropping seconds after it connects can't be minted again and again.
            if redialSessions > 0 {
                cancelStableTimer = scheduler.schedule(after: Self.stableAfter) { [weak self] in
                    self?.cancelStableTimer = nil
                    self?.redialSessions = 0
                }
            }
        }
        refreshStatus()
        onReconnecting?(reconnecting)
    }

    private func giveUpReconnecting() {
        guard !isEnded, isReconnecting else { return }
        if redialAttempt != nil { transport.cancelReconnect() }
        redialAttempt = nil
        let seconds = liveSince.map { Int(($0.duration(to: .now)).components.seconds) }
        VoiceCallLog.logger.notice("Reconnecting gave up after \(self.redialsThisDrop, privacy: .public) tries, \(self.redialSessions, privacy: .public) sessions minted")
        finish(.closed(seconds.map { "connection_lost, \($0)s" } ?? "connection_lost"), closesTransport: true)
    }

    private func redial() {
        guard !isEnded, redialAttempt == nil else { return }
        guard redialSessions < Self.redialSessionLimit else { return giveUpReconnecting() }
        redialSerial += 1
        redialsThisDrop += 1
        let attempt = redialSerial
        redialAttempt = attempt
        cancelRedialTimer = scheduler.schedule(after: Self.redialTimeout) { [weak self] in
            guard let self, self.redialAttempt == attempt else { return }
            self.transport.cancelReconnect()
            self.redialDidFail(attempt)
        }
        let history = redialHistory
        Task { [weak self, transport] in
            do {
                try await transport.reconnect(history: history)
                self?.redialDidConnect(attempt)
            } catch {
                self?.redialDidFail(attempt)
            }
        }
    }

    private func redialDidConnect(_ attempt: Int) {
        guard !isEnded, redialAttempt == attempt else { return }
        redialAttempt = nil
        cancelRedialTimer?(); cancelRedialTimer = nil
        VoiceCallLog.logger.notice("Redial \(self.redialsThisDrop, privacy: .public) connected")
        sessionDelegations = []
        sessionMuted = false
        isSpeaking = false
        // The new session never heard what the old one may not have said: from the earliest
        // unheard sentence on, a short repeat rather than a gap.
        let replay = unheardAtDrop.filter { replays[$0.delegationID, default: 0] < Self.maxReplays }
        for id in Set(replay.map(\.delegationID)) { replays[id, default: 0] += 1 }
        if !replay.isEmpty { VoiceCallLog.logger.notice("Redial says again \(replay.count, privacy: .public) unheard pieces") }
        heldSpeech = replay.map { (.say($0.text), $0.delegationID) } + heldSpeech
        unheardAtDrop = []
        setReconnecting(false)
    }

    private func redialDidFail(_ attempt: Int) {
        guard !isEnded, redialAttempt == attempt else { return }
        redialAttempt = nil
        cancelRedialTimer?(); cancelRedialTimer = nil
        VoiceCallLog.logger.notice("Redial \(self.redialsThisDrop, privacy: .public) failed")
        let wait = Self.redialBackoff[min(redialsThisDrop, Self.redialBackoff.count) - 1]
        cancelRedialTimer = scheduler.schedule(after: wait) { [weak self] in
            self?.cancelRedialTimer = nil
            self?.redial()
        }
    }

    /// A redial's seed: the chat's text turns, then what was said on the call, which the chat
    /// doesn't hold.
    private var redialHistory: [BotJSON] {
        VoiceLiveProtocol.liveHistory((chat?.voiceHistory ?? []) + VoiceLiveProtocol.turns(transcript.contextWindow))
    }

    // MARK: Voice events

    private func receive(_ event: VoiceLiveServerEvent) {
        guard !isEnded else { return }
        switch event {
        case .transcript(let fragment):
            transcript.append(fragment)
            showCaption(fragment)
            armInactivity()
            if fragment.speaker == .user { noteUserWords(fragment.text) }
        case .delegation(let id):
            sessionDelegations.insert(id)
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
        let (prompt, context) = VoiceLiveProtocol.delegationPrompt(transcript.contextWindow)
        // "Stop" is not work: handed to Hermes as a prompt it would start a new run.
        if VoiceLiveProtocol.isStopCommand(prompt) {
            if delegation != nil || queued != nil { stopRequests(answering: id) }
            return
        }
        if chat.turnAwaitsAnswer {
            speak(Line.stillWaiting, delegationID: id)
            return
        }
        // A turn that already started a tool may have acted: more talk waits for it rather than
        // stopping its work. Only a spoken stop cancels it.
        if let current = delegation, current.phase == .running, current.lastTool != nil {
            return queue(id, prompt: prompt, context: context)
        }
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
        // Only the Hermes connection running out drops a running turn, and a request queued
        // behind it can't go out either.
        queued = nil
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
        guard waiting.mayStopTurn, chat.isRunningTurn, !interruptSent else { return }
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
        logTiming("submitting", sending)
        let started = await chat?.submitVoice(prompt: sending.prompt, context: sending.context) ?? false
        logTiming(started ? "started" : "refused", sending)
        if stoppedWhileSubmitting == sending.id {
            stoppedWhileSubmitting = nil
            guard !isEnded else { return }
            return finishStop(answering: sending.id, stopsTurn: started)
        }
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
            noteFirstReply(&current)
            current.reply += text
            delegation = current
            speakFinishedSentences()
        case .interim(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            noteFirstReply(&current)
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
        if piece != nil, !current.spokeFirst {
            current.spokeFirst = true
            logTiming("first speech", current)
        }
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
        logTiming("settled", current)
        delegation = nil
        // The turn is over, so the queued request goes out once the chat is idle, never by a Stop.
        promoteQueued(mayStopTurn: false)
        refreshStatus()
        armInactivity()
        if delegation != nil { advance() }
    }

    // MARK: Queue and spoken stop

    /// Waits behind the running turn; requests made meanwhile join it, newest words kept.
    private func queue(_ id: String, prompt: String, context: String) {
        var next = Delegation(id: id, prompt: prompt, context: context)
        if let earlier = queued {
            next.prompt = String((earlier.prompt + "\n" + prompt).suffix(Self.maxQueuedPrompt))
        }
        next.mayStopTurn = false
        queued = next
        VoiceCallLog.logger.notice("Delegation queued behind a working turn")
        think(Line.queued, delegationID: id)
    }

    private func promoteQueued(mayStopTurn: Bool) {
        guard var next = queued else { return }
        queued = nil
        let id = next.id
        next.mayStopTurn = mayStopTurn
        next.cancelIdleWait = scheduler.schedule(after: Self.idleWait) { [weak self] in self?.idleWaitDidExpire(id) }
        delegation = next
    }

    /// The user's words so far; once they settle, a whole utterance that is a stop command
    /// cancels the request out. The voice model answers a bare "stop" itself and never delegates it.
    private func noteUserWords(_ text: String) {
        userUtterance += text
        cancelUtteranceSettle?()
        cancelUtteranceSettle = scheduler.schedule(after: Self.utteranceSettle) { [weak self] in
            guard let self, !self.isEnded else { return }
            self.cancelUtteranceSettle = nil
            let utterance = self.userUtterance
            self.userUtterance = ""
            guard VoiceLiveProtocol.isStopCommand(utterance), self.delegation != nil || self.queued != nil else { return }
            self.stopRequests(answering: nil)
        }
    }

    /// Cancels the request out and the one queued behind it, and stops the turn it started.
    private func stopRequests(answering spokenID: String?) {
        guard let id = delegation?.id ?? queued?.id else { return }
        let current = delegation
        delegation?.cancelIdleWait?()
        delegation = nil
        queued = nil
        refreshStatus()
        armInactivity()
        VoiceCallLog.logger.notice("Spoken stop cancels the request out")
        switch current?.phase {
        case .running?:
            finishStop(answering: spokenID ?? id, stopsTurn: true)
        case .submitting?:
            // Its turn may start any moment: `submit` stops it once the host answers.
            stoppedWhileSubmitting = current?.id
        case .waiting?, nil:
            speak(Line.stopped, delegationID: spokenID ?? id)
        }
    }

    /// Stops the turn the request started, and tells the voice how it went.
    private func finishStop(answering id: String, stopsTurn: Bool) {
        guard stopsTurn else { return speak(Line.stopped, delegationID: id) }
        Task { [weak self] in
            guard let self, let chat = self.chat else { return }
            self.interruptSent = true
            let stopped = await chat.interruptForVoice()
            if !stopped { self.interruptSent = false }
            self.speak(stopped ? Line.stopped : Line.stopRefused, delegationID: id)
        }
    }

    // MARK: Timing

    private func noteFirstReply(_ current: inout Delegation) {
        guard !current.heardFirstReply else { return }
        current.heardFirstReply = true
        logTiming("first reply", current)
    }

    /// How long after the voice's request each step came, in milliseconds only.
    private func logTiming(_ step: String, _ delegation: Delegation) {
        let elapsed = delegation.createdAt.duration(to: .now).components
        let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        VoiceCallLog.logger.notice("Delegation \(step, privacy: .public) after \(ms, privacy: .public) ms")
    }

    private func speak(_ text: String, delegationID: String) {
        send(.say(text), delegationID: delegationID)
    }

    private func think(_ text: String, delegationID: String) {
        send(.think(text), delegationID: delegationID)
    }

    /// Goes to the voice now, or once a wavering or redialed connection is back.
    private func send(_ utterance: Utterance, delegationID: String) {
        guard !isEnded else { return }
        guard !isReconnecting else { return heldSpeech.append((utterance, delegationID)) }
        let id = sessionDelegations.contains(delegationID) ? delegationID : nil
        switch utterance {
        case .say(let text):
            for event in events.commentary(text, delegationID: id) { transport.send(event) }
            trackUnheard(text, delegationID: delegationID)
        case .think(let text):
            if let event = events.thinking(text, delegationID: id) { transport.send(event) }
        }
    }

    /// Keeps a sentence until the voice has had time to say it: its turn in line after what is
    /// still unheard, its estimated length, and `heardSlack`.
    private func trackUnheard(_ text: String, delegationID: String) {
        spokenSerial += 1
        let serial = spokenSerial
        let duration = VoiceLiveProtocol.estimatedSpeech(text)
        let ahead = unheard.reduce(Duration.zero) { $0 + $1.duration }
        unheard.append(Spoken(serial: serial, text: text, delegationID: delegationID, duration: duration))
        _ = scheduler.schedule(after: ahead + duration + Self.heardSlack) { [weak self] in
            self?.unheard.removeAll { $0.serial == serial }
        }
    }
}
