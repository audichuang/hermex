import AVFoundation
import Observation
import UIKit

/// The app's one voice call (#1091). The call belongs to the app, not to the screen it started
/// on: this holds the call and its chat's model from the start until the call ends, so leaving
/// the chat, opening another or going to Settings keeps it talking. It ends on End, ten quiet
/// minutes, switching server or signing out, a Bot Chat the host replaced, or a dropped session.
@MainActor @Observable final class LiveVoiceCall {
    static let shared = LiveVoiceCall()

    /// The call while it is on.
    private(set) var call: HermesVoiceCall?
    /// The chat the call talks on. Held strongly, so its stream, its approval cards and the reply
    /// the call speaks outlive every view of it.
    @ObservationIgnored private(set) var model: ChatViewModel?
    /// The server and saved connection the call runs on.
    @ObservationIgnored private var host: (server: URL, connectionID: UUID)?
    /// New each time something asks to go back to the call's chat; the Hermes home routes there.
    private(set) var reopenRequest: UUID?
    /// The call fills the screen (`LiveVoiceCallScreen`); otherwise it is the floating pill.
    /// Every call starts full screen; swiping it down or Minimize makes it the pill.
    private(set) var isExpanded = false
    /// The last call dropped without the user hanging up: the bar says why and offers Call again
    /// until it is dismissed or another call starts.
    private(set) var drop: Drop? {
        didSet { droppedModel = drop?.model }
    }
    /// `drop`'s chat, for `model(for:)`, which must not read what a view observes.
    @ObservationIgnored private var droppedModel: ChatViewModel?

    struct Drop {
        let message: String
        /// The chat the call was on, kept for Call again.
        let model: ChatViewModel
        let server: URL
        let connectionID: UUID
    }

    /// The active server when it is a legacy webui server: its Bots chats offer no call, since
    /// the bar's way back to the call's chat lives in the Hermes home. `ContentView` sets it.
    @ObservationIgnored var webuiServer: URL?

    @ObservationIgnored private let tones = VoiceCallTones()

    init() {}

    /// `model` started `call`; held until `ended`. Rings until the session is up, then a
    /// connected beep and tap, like a phone call.
    func begin(_ call: HermesVoiceCall, model: ChatViewModel) {
        drop = nil
        self.call = call
        self.model = model
        host = model.hermesConversation.map { ($0.server, $0.connectionID) }
        isExpanded = true
        tones.ring()
        call.onLive = { [tones] in tones.connected() }
    }

    /// The pill goes back to the full-screen call.
    func expand() {
        guard call != nil else { return }
        isExpanded = true
    }

    /// The full-screen call becomes the pill over whatever screen is under it.
    func minimize() { isExpanded = false }

    /// Minimizes the call over its chat, for an approval or the reply in full.
    func showChat() {
        minimize()
        requestReopen()
    }

    /// `call` ended by any path; its chat is let go unless the call dropped, which keeps it
    /// for Call again.
    func ended(_ call: HermesVoiceCall) {
        guard call === self.call else { return }
        tones.stop()
        isExpanded = false
        if case .ended(let reason) = call.status, let message = ChatViewModel.voiceCallEndMessage(reason),
           let model, let host {
            drop = Drop(message: message, model: model, server: host.server, connectionID: host.connectionID)
        }
        self.call = nil
        model = nil
        host = nil
    }

    /// Goes back to the call's chat from wherever the app is.
    func requestReopen() {
        guard model != nil else { return }
        reopenRequest = UUID()
    }

    /// The chat the bar goes back to: the call's while it is on.
    var reopensTo: HermesSessionChat? { model?.hermesSeat }

    /// A view of the call's chat is on screen, so going back to it has nothing to close.
    var showsCallChat: Bool { (model?.viewsOnScreen ?? 0) > 0 }

    /// What going back to the call's chat takes on a side (Sessions or Bots) of the home.
    enum ReopenStep: Equatable {
        /// The chat is on screen.
        case stay
        /// Another chat or none is open there: open the call's.
        case open
        /// The call's chat is open under a pushed screen. Setting the same value again keeps
        /// that screen, so the side closes the chat and opens it again on the next turn.
        case reopen
    }

    /// `isOpen`: the side's open chat is the call's (its chat value, or its bot).
    func reopenStep(isOpen: Bool) -> ReopenStep {
        guard isOpen else { return .open }
        return showsCallChat ? .stay : .reopen
    }

    /// Starts a new call on the dropped call's chat and goes back to it.
    func callAgain() {
        guard let drop else { return }
        self.drop = nil
        // A chat whose connection was retired can't reach its host any more.
        guard !drop.model.hermesConnectionIsRetired, drop.model.startVoiceCall() != nil else { return }
        requestReopen()
    }

    func dismissDrop() { drop = nil }

    /// The model of the call's chat when `chat` opens that chat, so its new view takes the
    /// call's model instead of making another; after a drop, the dropped call's, which Call
    /// again calls on. Reads nothing a view observes: `ChatView.init`
    /// calls it inside its parent's update.
    ///
    /// Each opening of a chat is a new `HermesSessionChat`, so a match is the chat value that
    /// opened it (a new session, until its first prompt, has nothing else), or the same server,
    /// connection and target: the Profile's Bot Chat, or the session by its current key or its
    /// lineage root.
    func model(for chat: HermesSessionChat) -> ChatViewModel? {
        guard let model = model ?? droppedModel, !model.hermesConnectionIsRetired else { return nil }
        if model.hermesSeat?.id == chat.id { return model }
        guard let conversation = model.hermesConversation, conversation.server == chat.server,
              conversation.connectionID == chat.connection.id else { return nil }
        switch chat.target {
        case .canonicalChat(let profile):
            guard case .canonicalChat(profile) = conversation.target else { return nil }
            return model
        case .session(let profile, let key):
            guard conversation.target.profile == profile else { return nil }
            if case .session(_, key) = conversation.target { return model }
            if model.hermesSessionLink?.key == key { return model }
            if let root = model.hermesLineageRoot, root == chat.lineageRoot ?? key { return model }
            return nil
        case .new:
            return nil
        }
    }

    /// The active signed-in server is now `server` (nil: signed out or none): a call on any other
    /// ends, since everything scoped to a server goes with it.
    func endUnless(server: URL?) {
        if let drop, drop.server != server { self.drop = nil }
        guard let call, let host, host.server != server else { return }
        call.end()
    }

    /// `server`'s saved connection is now `connectionID` (nil: removed). A call on a replaced
    /// record ends, as a sign-out would.
    func endUnless(connectionID: UUID?, on server: URL) {
        if let drop, drop.server == server, drop.connectionID != connectionID { self.drop = nil }
        guard let call, let host, host.server == server, host.connectionID != connectionID else { return }
        call.end()
    }
}

/// A call's ringback while it connects and the beep once it is up, made here as tones so no
/// sound file ships. They play beside WebRTC's audio and never go into the microphone track.
@MainActor final class VoiceCallTones {
    private var player: AVAudioPlayer?
    private let haptics = UINotificationFeedbackGenerator()

    /// 440 + 480 Hz for a second, then two quiet ones, over and over until `stop` or `connected`.
    func ring() {
        play(Self.wave([(1.0, [440, 480]), (2.0, [])]), loops: -1)
        haptics.prepare()
    }

    /// Stops the ringback, beeps twice rising and taps.
    func connected() {
        play(Self.wave([(0.08, [880]), (0.06, []), (0.12, [1320])]), loops: 0)
        haptics.notificationOccurred(.success)
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func play(_ data: Data, loops: Int) {
        stop()
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.numberOfLoops = loops
        player.volume = 0.35
        player.play()
        self.player = player
    }

    /// 16-bit mono WAV of `parts`: each a length in seconds and the frequencies summed in it
    /// (none: silence), with short fades so no part clicks.
    static func wave(_ parts: [(seconds: Double, hertz: [Double])]) -> Data {
        let rate = 16_000.0
        var samples: [Int16] = []
        for part in parts {
            let count = Int(part.seconds * rate)
            let fade = min(Double(count) / 2, rate * 0.01)
            for index in 0..<count {
                guard !part.hertz.isEmpty else { samples.append(0); continue }
                let time = Double(index) / rate
                let sum = part.hertz.reduce(0) { $0 + sin(2 * .pi * $1 * time) } / Double(part.hertz.count)
                let edge = min(1, Double(index) / fade, Double(count - index) / fade)
                samples.append(Int16(sum * edge * 0.6 * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        samples.forEach { append($0) }
        return data
    }
}
