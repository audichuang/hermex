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

    init() {}

    /// `model` started `call`; held until `ended`.
    func begin(_ call: HermesVoiceCall, model: ChatViewModel) {
        drop = nil
        self.call = call
        self.model = model
        host = model.hermesConversation.map { ($0.server, $0.connectionID) }
    }

    /// `call` ended by any path; its chat is let go unless the call dropped, which keeps it
    /// for Call again.
    func ended(_ call: HermesVoiceCall) {
        guard call === self.call else { return }
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
