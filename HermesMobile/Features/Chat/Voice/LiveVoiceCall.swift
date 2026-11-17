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
    /// New each time something asks to go back to the call's chat; the Hermes home routes there.
    private(set) var reopenRequest: UUID?

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

    /// Goes back to the call's chat from wherever the app is.
    func requestReopen() {
        guard model != nil else { return }
        reopenRequest = UUID()
    }

    /// The model of the call's chat when `chat` opens that chat, so its new view takes the
    /// call's model instead of making another. Reads nothing a view observes: `ChatView.init`
    /// calls it inside its parent's update.
    ///
    /// Each opening of a chat is a new `HermesSessionChat`, so a match is the chat value that
    /// opened it (a new session, until its first prompt, has nothing else), or the same server,
    /// connection and target: the Profile's Bot Chat, or the session by its current key or its
    /// lineage root.
    func model(for chat: HermesSessionChat) -> ChatViewModel? {
        guard let model else { return nil }
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
