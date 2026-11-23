import Foundation

struct BotRoomDestination: Equatable, Hashable {
    let server: URL
    let connectionID: UUID
    let roomID: String
}

extension HermesDeepLink {
    static let botRoomHost = "bot-room"
    private static let roomConnectionQueryItem = "connection"
    private static let roomQueryItem = "room"

    static func botRoomURL(for destination: BotRoomDestination) -> URL? {
        let room = destination.roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = botRoomHost
        components.queryItems = [
            URLQueryItem(name: serverQueryItem, value: destination.server.absoluteString),
            URLQueryItem(name: roomConnectionQueryItem, value: destination.connectionID.uuidString),
            URLQueryItem(name: roomQueryItem, value: room)
        ]
        return components.url
    }

    static func botRoomDestination(from url: URL) -> BotRoomDestination? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == botRoomHost else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let text = items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }

        guard let rawServer = value(serverQueryItem),
              let server = try? AuthManager.normalizedServerURL(from: rawServer),
              let connectionID = value(roomConnectionQueryItem).flatMap(UUID.init(uuidString:)),
              let roomID = value(roomQueryItem)
        else {
            return nil
        }
        return BotRoomDestination(server: server, connectionID: connectionID, roomID: roomID)
    }
}

enum BotRoomDeepLinkOutcome: Equatable {
    case ignore
    case waitForSignIn(BotRoomDestination)
    case switchServer(ServerAccount, BotRoomDestination)
    case open(BotRoomDestination)
}

enum BotRoomLinkDecision: Equatable {
    case wait
    case open(BotRoomKey)
    case missing
}

@MainActor enum BotRoomDeepLinkRouter {
    static func resolve(
        _ destination: BotRoomDestination,
        state: AuthManager.State,
        servers: [ServerAccount],
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> BotRoomDeepLinkOutcome {
        guard let account = servers.first(where: { $0.id == destination.server.absoluteString }),
              account.kind == .hermes,
              botConnectionID(destination.server) == destination.connectionID
        else {
            return .ignore
        }

        switch state {
        case .loggedIn(let active) where active == destination.server:
            return .open(destination)
        case .loggedIn:
            return .switchServer(account, destination)
        case .loggedOut, .unconfigured:
            return .waitForSignIn(destination)
        }
    }

    static func decide(
        _ destination: BotRoomDestination, canAnswer: Bool, connectionID: UUID?, loadedRoomIDs: Set<String>?
    ) -> BotRoomLinkDecision {
        guard canAnswer else { return .wait }
        guard connectionID == destination.connectionID, loadedRoomIDs?.contains(destination.roomID) == true else {
            return .missing
        }
        return .open(BotRoomKey(server: destination.server, connectionID: destination.connectionID,
                                roomID: destination.roomID))
    }
}

extension PendingLinks {
    @MainActor mutating func route(
        _ destination: BotRoomDestination, state: AuthManager.State, servers: [ServerAccount],
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> ServerAccount? {
        switch BotRoomDeepLinkRouter.resolve(destination, state: state, servers: servers,
                                             botConnectionID: botConnectionID) {
        case .ignore:
            botRoom = nil
        case .waitForSignIn(let destination), .open(let destination):
            bot = nil
            botRoom = destination
        case .switchServer(let account, let destination):
            bot = nil
            botRoom = destination
            return account
        }
        return nil
    }
}
