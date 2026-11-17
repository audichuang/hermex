import Foundation
import Observation

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

    init() {}

    /// `model` started `call`; held until `ended`.
    func begin(_ call: HermesVoiceCall, model: ChatViewModel) {
        self.call = call
        self.model = model
        host = model.hermesConversation.map { ($0.server, $0.connectionID) }
    }

    /// `call` ended by any path; its chat is let go.
    func ended(_ call: HermesVoiceCall) {
        guard call === self.call else { return }
        self.call = nil
        model = nil
        host = nil
    }

    /// The active signed-in server is now `server` (nil: signed out or none): a call on any other
    /// ends, since everything scoped to a server goes with it.
    func endUnless(server: URL?) {
        guard let call, let host, host.server != server else { return }
        call.end()
    }

    /// `server`'s saved connection is now `connectionID` (nil: removed). A call on a replaced
    /// record ends, as a sign-out would.
    func endUnless(connectionID: UUID?, on server: URL) {
        guard let call, let host, host.server == server, host.connectionID != connectionID else { return }
        call.end()
    }
}
