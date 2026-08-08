import Foundation

extension APIClient {
    /// Parameterless overload kept so `InsightsDataClient` (and any other
    /// protocol witness) still sees the exact `sessions()` signature — a method
    /// with defaulted parameters cannot satisfy that requirement.
    func sessions() async throws -> SessionsResponse {
        try await sessions(includeArchived: false, archivedLimit: nil)
    }

    /// Fetches the session list. `includeArchived` opts in to archived rows
    /// (merged with the visible ones; each row carries an `archived` flag) and
    /// `archivedLimit` optionally caps how many archived rows the server appends
    /// (issue #17). Defaults keep today's request untouched.
    func sessions(includeArchived: Bool = false, archivedLimit: Int? = nil) async throws -> SessionsResponse {
        try await send(
            endpoint: .sessions(includeArchived: includeArchived, archivedLimit: archivedLimit),
            method: "GET"
        )
    }

    func searchSessions(query: String, content: Bool = true, depth: Int = 5) async throws -> SessionSearchResponse {
        try await send(
            endpoint: .sessionsSearch(query: query, content: content, depth: depth),
            method: "GET"
        )
    }

    func session(
        id: String,
        includeMessages: Bool = true,
        messageLimit: Int? = 50,
        messageBefore: Int? = nil,
        expandRenderable: Bool = false
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .session(
                id: id,
                includeMessages: includeMessages,
                messageLimit: messageLimit,
                messageBefore: messageBefore,
                expandRenderable: expandRenderable
            ),
            method: "GET"
        )
    }

    func sessionStatus(id: String) async throws -> SessionStatusResponse {
        try await send(endpoint: .sessionStatus(id: id), method: "GET")
    }

    /// Imports a CLI or messaging session into the WebUI-owned session store.
    /// The returned session is authoritative for whether continuation is safe.
    func importExternalSession(id: String) async throws -> SessionResponse {
        try await send(
            endpoint: .importCLISession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    /// Creates a session.
    ///
    /// `previousSessionID` is the session the user is coming *from*, when there
    /// is one. Upstream uses it to commit that session's memory before the new
    /// one starts (`prev_session_id` in `api/routes.py`); omitting it skips that
    /// step entirely, so a chat started from another chat loses the handoff.
    ///
    /// `worktree` is always sent explicitly — see `NewSessionRequest.worktree`.
    func createSession(
        workspace: String?,
        model: String?,
        modelProvider: String?,
        profile: String?,
        previousSessionID: String? = nil,
        worktree: Bool = false
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .newSession,
            method: "POST",
            body: NewSessionRequest(
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile,
                prevSessionId: previousSessionID,
                worktree: worktree
            )
        )
    }

    func renameSession(id: String, title: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .renameSession,
            method: "POST",
            body: RenameSessionRequest(sessionId: id, title: title)
        )
    }

    func deleteSession(id: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .deleteSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func pinSession(id: String, pinned: Bool) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .pinSession,
            method: "POST",
            body: PinSessionRequest(sessionId: id, pinned: pinned)
        )
    }

    func archiveSession(id: String, archived: Bool) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .archiveSession,
            method: "POST",
            body: ArchiveSessionRequest(sessionId: id, archived: archived)
        )
    }

    func branchSession(id: String, keepCount: Int? = nil, title: String? = nil) async throws -> SessionBranchResponse {
        try await send(
            endpoint: .branchSession,
            method: "POST",
            body: BranchSessionRequest(sessionId: id, keepCount: keepCount, title: title)
        )
    }

    /// Copies a session. Answers with the whole duplicated session, so no
    /// follow-up fetch is needed. Rejects subagent sessions with a 400 — they
    /// are view-only upstream.
    func duplicateSession(id: String) async throws -> SessionResponse {
        try await send(
            endpoint: .duplicateSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    /// Compresses a session and waits for the result.
    ///
    /// Starts the asynchronous job the web client uses and polls it, rather than
    /// holding one request open for the whole compression. The synchronous
    /// `/api/session/compress` runs the same work inline, so a long transcript
    /// reliably exceeded the request timeout — and the compression then finished
    /// on the server anyway, rotating the session id behind a client that had
    /// already given up (#24, and #2 for what that rotation costs).
    ///
    /// A server without the asynchronous routes answers the start with 404;
    /// that falls back to the synchronous call so an older deployment keeps
    /// working.
    func compressSession(
        id: String,
        focusTopic: String? = nil,
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(600)
    ) async throws -> SessionCompressResponse {
        let body = CompressSessionRequest(sessionId: id, focusTopic: focusTopic)

        let started: SessionCompressResponse
        do {
            started = try await send(endpoint: .compressSessionStart, method: "POST", body: body)
        } catch APIError.http(let statusCode, _) where statusCode == 404 {
            return try await send(endpoint: .compressSession, method: "POST", body: body)
        }

        guard started.isJobRunning else { return started }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var latest = started
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            latest = try await send(endpoint: .compressSessionStatus(sessionID: id), method: "GET")
            guard latest.isJobRunning else { return latest }
        }

        throw APIError.http(statusCode: 408, body: nil)
    }

    /// Truncates the session to empty on the server and resets its title to
    /// Untitled. Destructive and irreversible — only call it behind a
    /// confirmation. Answers the same compact session shape as rename (#389).
    func clearSession(id: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .clearSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func undoSession(id: String) async throws -> SessionUndoResponse {
        try await send(
            endpoint: .undoSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func retrySession(id: String) async throws -> SessionRetryResponse {
        try await send(
            endpoint: .retrySession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func truncateSession(id: String, keepCount: Int) async throws -> SessionResponse {
        try await send(
            endpoint: .truncateSession,
            method: "POST",
            body: TruncateSessionRequest(sessionId: id, keepCount: keepCount)
        )
    }

    func updateSession(
        id: String,
        workspace: String?,
        model: String?,
        modelProvider: String?
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .updateSession,
            method: "POST",
            body: UpdateSessionRequest(
                sessionId: id,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider
            )
        )
    }

    func moveSession(id: String, projectID: String?) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .moveSession,
            method: "POST",
            body: MoveSessionRequest(sessionId: id, projectId: projectID)
        )
    }

    func sessionYolo(sessionID: String) async throws -> SessionYoloResponse {
        try await send(endpoint: .sessionYolo(sessionID: sessionID), method: "GET")
    }

    func setSessionYolo(sessionID: String, enabled: Bool) async throws -> SessionYoloResponse {
        try await send(
            endpoint: .sessionYolo(sessionID: nil),
            method: "POST",
            body: SessionYoloRequest(sessionId: sessionID, enabled: enabled)
        )
    }
}

private struct NewSessionRequest: Encodable {
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
    let prevSessionId: String?
    /// Non-optional on purpose, so it is always on the wire.
    ///
    /// Upstream reads this key by *presence*, not truthiness: an absent
    /// `worktree` means "inherit the profile's config-level `worktree:`
    /// default" (`worktree_explicit` in `api/routes.py`). A server configured
    /// with `worktree: true` would therefore create a git worktree for every
    /// session the app opens and silently replace the session's workspace with
    /// the worktree path. Upstream's own comment says a client that must not
    /// create one has to send `false` explicitly — so Hermex always states it.
    let worktree: Bool
}

private struct RenameSessionRequest: Encodable {
    let sessionId: String
    let title: String
}

private struct SessionIDRequest: Encodable {
    let sessionId: String
}

private struct PinSessionRequest: Encodable {
    let sessionId: String
    let pinned: Bool
}

private struct ArchiveSessionRequest: Encodable {
    let sessionId: String
    let archived: Bool
}

private struct BranchSessionRequest: Encodable {
    let sessionId: String
    let keepCount: Int?
    let title: String?
}

private struct CompressSessionRequest: Encodable {
    let sessionId: String
    let focusTopic: String?
}

private struct TruncateSessionRequest: Encodable {
    let sessionId: String
    let keepCount: Int
}

private struct UpdateSessionRequest: Encodable {
    let sessionId: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
}

private struct MoveSessionRequest: Encodable {
    let sessionId: String
    let projectId: String?
}

private struct SessionYoloRequest: Encodable {
    let sessionId: String
    let enabled: Bool
}
