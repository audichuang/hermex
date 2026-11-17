import AVFoundation
import Foundation
import WebRTC

/// Trades a call's WebRTC offer for the host-minted GPT-Live session seeded with `history`
/// (`BotClient.voiceLiveSession` for the chat's Profile).
typealias VoiceLiveSessionOpener = @MainActor (_ sdp: String, _ history: [BotJSON]) async throws -> HermesVoiceLiveSession

enum VoiceLiveTransportError: LocalizedError {
    case microphoneDenied
    /// WebRTC could not build the peer connection, the offer or the data channel.
    case peerConnectionFailed
    /// The session ended (interruption, lost connection) before it finished opening.
    case endedWhileStarting

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return String(localized: "Microphone access is disabled. Enable it in Settings to make a voice call.")
        case .peerConnectionFailed, .endedWhileStarting:
            return String(localized: "The voice call could not connect. Try again in a moment.")
        }
    }
}

/// The WebRTC transport for a GPT-Live voice call (#1091), Hermes Desktop's `voice-live.ts`:
/// one audio-only peer connection to OpenAI and its `oai-events` data channel. The host only
/// mints the session; call audio goes from the phone straight to the vendor. It holds the
/// microphone and the shared audio session (`ComposerAudioCaptureState.claimCall`) from opening
/// until it tears down and puts the session back; a newer call tears it down first. The host
/// has no route that ends a session, so closing the peer connection is the only way to stop
/// billing: every path ends in `finalize`.
@MainActor final class WebRTCVoiceLiveTransport: VoiceLiveTransport {
    static let dataChannelLabel = "oai-events"
    static let iceGatheringTimeout: Duration = .seconds(10)
    static let closeTimeout: Duration = .seconds(15)
    /// Fast enough for the call bar's waveform to follow speech.
    static let speakingProbeInterval: Duration = .milliseconds(100)
    /// Inbound `audioLevel` (0...1) above which the voice counts as talking.
    static let speakingLevel = 0.03
    /// Quiet readings in a row (half a second) before the voice counts as done talking.
    static let quietProbesToStop = 5

    var onEvent: ((VoiceLiveServerEvent) -> Void)?
    var onClosed: ((String) -> Void)?
    var onSpeakingChange: ((Bool) -> Void)?
    var onAudioLevel: ((Double) -> Void)?

    private let openSession: VoiceLiveSessionOpener
    private let relay = WebRTCVoiceLiveRelay()
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var audioSession: VoiceCallAudioSession?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var gathering: CheckedContinuation<Void, Never>?
    private var closeTimer: Task<Void, Never>?
    private var speakingProbe: Task<Void, Never>?
    private var isSpeaking = false
    /// Starts quiet, so the first silent reading is not a blip of Speaking.
    private var quietProbes = quietProbesToStop
    private var isMuted = false
    private var didStart = false
    private var closeRequested = false
    private var finalized = false

    init(openSession: @escaping VoiceLiveSessionOpener) {
        self.openSession = openSession
        relay.owner = self
    }

    // MARK: VoiceLiveTransport

    func start(history: [BotJSON]) async throws {
        guard !didStart, !finalized else { throw VoiceLiveTransportError.endedWhileStarting }
        didStart = true
        do {
            try await open(history: history)
        } catch {
            // Torn down silently: the call reports the start failure itself, and its `close()` is a no-op.
            finalize(reason: nil)
            throw error
        }
    }

    func send(_ event: BotJSON) {
        _ = sendNow(event)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        microphone?.isEnabled = !muted
    }

    /// Desktop's graceful close: ask for `session.closed`, tear down when it comes or after 15 s.
    /// The user hears and is heard no more from now on. A session still opening has no open
    /// channel, so it tears down at once and the opening stops at its next step. The timer holds
    /// the transport, so a call its owner already dropped still tears down.
    func close() {
        guard !finalized, !closeRequested else { return }
        closeRequested = true
        microphone?.isEnabled = false
        peer?.receivers.forEach { $0.track?.isEnabled = false }
        guard sendNow(VoiceLiveClientEvents.close) else { return finalize(reason: "close_requested") }
        closeTimer = Task {
            try? await Task.sleep(for: Self.closeTimeout)
            guard !Task.isCancelled else { return }
            self.finalize(reason: "close_requested")
        }
    }

    // MARK: Opening

    private func open(history: [BotJSON]) async throws {
        guard await ComposerVoiceMicrophonePermissionRequester.request() else {
            throw VoiceLiveTransportError.microphoneDenied
        }
        try checkStillOpening()
        // Before the session is read, so a call still tearing down puts it back first.
        ComposerAudioCaptureState.shared.claimCall(self) { [self] in
            _ = sendNow(VoiceLiveClientEvents.close)
            finalize(reason: "replaced")
        }
        audioSession = try VoiceCallAudioSession.begin()
        observeInterruptions()

        _ = Self.sslReady
        let factory = RTCPeerConnectionFactory()
        self.factory = factory
        let configuration = RTCConfiguration()
        // No STUN or TURN, like Desktop's `new RTCPeerConnection()`: host candidates reach the vendor.
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: none, delegate: relay) else {
            throw VoiceLiveTransportError.peerConnectionFailed
        }
        self.peer = peer

        // Desktop's getUserMedia({ echoCancellation, noiseSuppression, autoGainControl }); the
        // `.voiceChat` audio unit adds the hardware echo canceller underneath.
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "googEchoCancellation": kRTCMediaConstraintsValueTrue,
            "googNoiseSuppression": kRTCMediaConstraintsValueTrue,
            "googAutoGainControl": kRTCMediaConstraintsValueTrue,
            "googHighpassFilter": kRTCMediaConstraintsValueTrue,
        ]))
        let track = factory.audioTrack(with: source, trackId: "hermex-microphone")
        guard peer.add(track, streamIds: ["hermex-call"]) != nil else { throw VoiceLiveTransportError.peerConnectionFailed }
        microphone = track

        // Registered before the offer so its m-line is negotiated.
        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: Self.dataChannelLabel, configuration: channelConfiguration) else {
            throw VoiceLiveTransportError.peerConnectionFailed
        }
        channel.delegate = relay
        self.channel = channel

        let offer = try await Self.offer(peer)
        try checkStillOpening()
        try await Self.setLocal(offer, on: peer)
        try checkStillOpening()
        await iceGatheringComplete(peer)
        try checkStillOpening()
        // Byte-exact: the host forwards it to the vendor, which refuses a stripped offer.
        guard let sdp = peer.localDescription?.sdp, !sdp.isEmpty else { throw VoiceLiveTransportError.peerConnectionFailed }

        let session = try await openSession(sdp, history)
        try checkStillOpening()
        try await Self.setRemote(session.answerSDP, on: peer)
        try checkStillOpening()
        armSpeakingProbe()
    }

    private func checkStillOpening() throws {
        if finalized { throw VoiceLiveTransportError.endedWhileStarting }
    }

    /// Non-trickle: the offer goes out with its candidates, so wait for gathering to finish, at
    /// most 10 s, then send what there is.
    private func iceGatheringComplete(_ peer: RTCPeerConnection) async {
        guard peer.iceGatheringState != .complete else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.iceGatheringTimeout)
            self?.resumeGathering()
        }
        await withCheckedContinuation { gathering = $0 }
        timeout.cancel()
    }

    private func resumeGathering() {
        gathering?.resume()
        gathering = nil
    }

    private static let sslReady: Bool = RTCInitializeSSL()

    private static func offer(_ peer: RTCPeerConnection) async throws -> String {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                if let sdp = description?.sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: error ?? VoiceLiveTransportError.peerConnectionFailed)
                }
            }
        }
    }

    private static func setLocal(_ sdp: String, on peer: RTCPeerConnection) async throws {
        let description = RTCSessionDescription(type: .offer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func setRemote(_ sdp: String, on peer: RTCPeerConnection) async throws {
        let description = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: Relayed WebRTC events (main actor, in arrival order)

    fileprivate func gatheringDidChange(_ state: RTCIceGatheringState) {
        if state == .complete { resumeGathering() }
    }

    fileprivate func connectionDidChange(_ state: RTCPeerConnectionState) {
        if state == .failed || state == .disconnected { finalize(reason: "connection_lost") }
    }

    fileprivate func channelDidChange(_ state: RTCDataChannelState) {
        if state == .closed { finalize(reason: "connection_lost") }
    }

    fileprivate func channelDidReceive(_ data: Data) {
        guard !finalized, let event = VoiceLiveServerEvent.decode(data) else { return }
        if case .closed(let reason, _) = event { return finalize(reason: reason) }
        onEvent?(event)
    }

    fileprivate func audioLevels(inbound: Double?, microphone: Double?) {
        guard !finalized else { return }
        // A muted microphone's source still hears the room; the waveform must not.
        let heard = isMuted ? 0 : microphone ?? 0
        onAudioLevel?(max(inbound ?? 0, heard))
        guard let level = inbound else { return }
        let loud = level > Self.speakingLevel
        quietProbes = loud ? 0 : quietProbes + 1
        let speaking = loud || quietProbes < Self.quietProbesToStop
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        onSpeakingChange?(speaking)
    }

    // MARK: Speaking probe

    /// Desktop's analyser on the voice's track: the inbound audio level, polled while the call is
    /// up, and the microphone's for the waveform. Without a reading the call simply never shows
    /// Speaking.
    private func armSpeakingProbe() {
        speakingProbe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.speakingProbeInterval)
                guard !Task.isCancelled, let peer = self?.peer else { return }
                let report = await peer.statistics()
                func level(_ type: String) -> Double? {
                    report.statistics.values.first {
                        $0.type == type && ($0.values["kind"] as? String) == "audio"
                    }.flatMap { ($0.values["audioLevel"] as? NSNumber)?.doubleValue }
                }
                self?.audioLevels(inbound: level("inbound-rtp"), microphone: level("media-source"))
            }
        }
    }

    // MARK: Interruption

    /// A phone call or Siri takes the audio session: the call ends. A route change does not.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            guard type == .began else { return }
            MainActor.assumeIsolated {
                guard let self, !self.finalized else { return }
                _ = self.sendNow(VoiceLiveClientEvents.close)
                self.finalize(reason: "interrupted")
            }
        }
    }

    // MARK: Teardown

    @discardableResult
    private func sendNow(_ event: BotJSON) -> Bool {
        guard !finalized, let channel, channel.readyState == .open,
              let data = try? JSONEncoder().encode(event) else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// Ends the session once: releases the microphone, the peer connection and the audio
    /// session, then reports `reason` (none when `start` throws instead).
    private func finalize(reason: String?) {
        guard !finalized else { return }
        finalized = true
        closeTimer?.cancel(); closeTimer = nil
        speakingProbe?.cancel(); speakingProbe = nil
        resumeGathering()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        relay.owner = nil
        channel?.delegate = nil
        channel?.close()
        microphone?.isEnabled = false
        peer?.close()
        channel = nil; microphone = nil; peer = nil; factory = nil
        audioSession?.end(); audioSession = nil
        ComposerAudioCaptureState.shared.releaseCall(self)
        if isSpeaking { isSpeaking = false; onSpeakingChange?(false) }
        onAudioLevel?(0)
        if let reason { onClosed?(closeRequested ? "close_requested" : reason) }
    }
}

/// WebRTC calls its delegates on its own threads. This forwards each event to the transport on
/// the main queue, keeping their order, with only Sendable values crossing over.
private final class WebRTCVoiceLiveRelay: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    /// Read and written on the main thread only.
    nonisolated(unsafe) weak var owner: WebRTCVoiceLiveTransport?

    func deliver(_ action: @escaping @MainActor (WebRTCVoiceLiveTransport) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let owner = self.owner else { return }
                action(owner)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        deliver { $0.gatheringDidChange(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        deliver { $0.connectionDidChange(newState) }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        deliver { $0.channelDidChange(state) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        let data = buffer.data
        deliver { $0.channelDidReceive(data) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// The shared audio session during a call: `.playAndRecord` + `.voiceChat` on the speaker,
/// Bluetooth allowed, also as the configuration WebRTC applies when its audio unit starts.
/// `end()` puts back what was there before.
@MainActor private struct VoiceCallAudioSession {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let webRTCDefault: RTCAudioSessionConfiguration

    static func begin() throws -> VoiceCallAudioSession {
        let session = RTCAudioSession.sharedInstance()
        let previous = VoiceCallAudioSession(
            category: session.session.category, mode: session.session.mode,
            options: session.session.categoryOptions, webRTCDefault: RTCAudioSessionConfiguration.webRTC()
        )
        let call = RTCAudioSessionConfiguration()
        call.category = AVAudioSession.Category.playAndRecord.rawValue
        call.mode = AVAudioSession.Mode.voiceChat.rawValue
        call.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(call)
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setConfiguration(call, active: true)
            // The connected tap still plays while the microphone records.
            try? session.session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            RTCAudioSessionConfiguration.setWebRTC(previous.webRTCDefault)
            throw error
        }
        return previous
    }

    /// `setActive(false)` deactivates on the last balanced call with
    /// `.notifyOthersOnDeactivation` (`RTCAudioSession.h`), so music paused by the call resumes.
    func end() {
        let session = RTCAudioSession.sharedInstance()
        RTCAudioSessionConfiguration.setWebRTC(webRTCDefault)
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setActive(false)
        try? session.setCategory(category, mode: mode, options: options)
    }
}
