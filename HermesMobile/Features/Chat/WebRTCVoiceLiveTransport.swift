import Foundation
import WebRTC

/// The WebRTC transport for a GPT-Live voice call (#1091). It owns the peer
/// connection to OpenAI and the `oai-events` data channel; the host only mints
/// the session. Filled in by the transport step; for now it proves the WebRTC
/// package links into the app target.
final class WebRTCVoiceLiveTransport {
    static let dataChannelLabel = "oai-events"
    private static let peerConnectionType = RTCPeerConnection.self
}
