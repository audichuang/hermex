import Foundation

@MainActor enum BotChatMint {
    private struct Key: Hashable {
        let server: URL
        let connectionID: UUID
        let profile: String
    }

    private static var pending: [Key: Task<Void, Error>] = [:]

    static func findChat(profile: String, using client: any BotTransport,
                         validate: @escaping () throws -> Void) async throws -> [BotJSON] {
        try validate()
        let lookup = try await client.call(.sessionList(profile: profile), validateDispatch: validate)
        try validate()
        guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
        return rows
    }

    static func ensureChat(profile: String, server: URL, connectionID: UUID, using client: any BotTransport,
                           validate: @escaping () throws -> Void) async throws {
        try validate()
        let key = Key(server: server, connectionID: connectionID, profile: profile)
        while let existing = pending[key] {
            do {
                try await existing.value
            } catch BotFailure.stale, is CancellationError {
                try validate()
                continue
            }
            try validate()
            return
        }

        let task = Task {
            defer { pending[key] = nil }
            try await mintIfMissing(profile: profile, using: client, validate: validate)
        }
        pending[key] = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try validate()
    }

    private static func mintIfMissing(profile: String, using client: any BotTransport,
                                      validate: @escaping () throws -> Void) async throws {
        guard try await findChat(profile: profile, using: client, validate: validate).isEmpty else { return }
        await client.keepPlatformNote(profile: profile)
        try validate()
        let created = try await client.call(.sessionCreate(profile: profile), validateDispatch: validate)
        try validate()
        guard let runtime = created["session_id"].text, !runtime.isEmpty else { throw BotFailure.unsupported }
        guard !client.speaksCanonicalProtocol else { return }
        do {
            _ = try await client.call(.sessionTitle(sessionID: runtime), validateDispatch: validate)
            try validate()
        } catch BotFailure.rejected(4022) {
            let rows = try await findChat(profile: profile, using: client, validate: validate)
            guard !rows.isEmpty else { throw BotFailure.unsupported }
        }
    }
}
