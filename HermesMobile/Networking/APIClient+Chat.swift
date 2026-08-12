import Foundation

extension APIClient {
    func startChat(
        sessionID: String,
        message: String,
        workspace: String?,
        model: String?,
        modelProvider: String? = nil,
        profile: String? = nil,
        explicitModelPick: Bool = false,
        attachments: [JSONValue]? = nil
    ) async throws -> ChatStartResponse {
        try await send(
            endpoint: .chatStart,
            method: "POST",
            body: ChatStartRequest(
                sessionId: sessionID,
                message: message,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile,
                explicitModelPick: explicitModelPick ? true : nil,
                attachments: attachments
            )
        )
    }

    /// Builds the chat-stream URL, carrying a replay cursor when there is one.
    ///
    /// A replay sends both parameters, because the server trusts them
    /// differently: `after_event_id` is checked against the stream's own run id
    /// and rejects a cursor from a different run, while a bare `after_seq` is
    /// taken at face value (`_parse_run_journal_after_seq`,
    /// `api/routes.py:17151` @ 399cd7ab). Sending only the sequence number meant
    /// a cursor from a replaced run — a compression, a retry, a gateway restart
    /// — could resume against the wrong event stream, and the client was
    /// actively stripping the run id out of the id it already had. Sending it is
    /// how that check gets bought back (#9).
    nonisolated func chatStreamURL(
        streamID: String,
        replayAfterSeq: Int? = nil,
        replayAfterEventID: String? = nil
    ) -> URL {
        let url = Endpoint.chatStream(streamID: streamID).url(relativeTo: baseURL)
        guard let replayAfterSeq,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "replay", value: "1"))
        queryItems.append(URLQueryItem(name: "after_seq", value: "\(max(0, replayAfterSeq))"))
        if let replayAfterEventID, !replayAfterEventID.isEmpty {
            queryItems.append(URLQueryItem(name: "after_event_id", value: replayAfterEventID))
        }
        components.queryItems = queryItems
        return components.url ?? url
    }

    func cancelChat(streamID: String) async throws -> ChatCancelResponse {
        try await send(endpoint: .chatCancel(streamID: streamID), method: "GET")
    }

    func chatStreamStatus(streamID: String) async throws -> ChatStreamStatusResponse {
        try await send(endpoint: .chatStreamStatus(streamID: streamID), method: "GET")
    }

    func approvalPending(sessionID: String) async throws -> ApprovalPendingResponse {
        try await send(endpoint: .approvalPending(sessionID: sessionID), method: "GET")
    }

    nonisolated func approvalStreamURL(sessionID: String) -> URL {
        Endpoint.approvalStream(sessionID: sessionID).url(relativeTo: baseURL)
    }

    func respondApproval(
        sessionID: String,
        choice: ApprovalChoice,
        approvalID: String?
    ) async throws -> ApprovalRespondResponse {
        try await send(
            endpoint: .approvalRespond,
            method: "POST",
            body: ApprovalRespondRequest(
                sessionId: sessionID,
                choice: choice,
                approvalId: approvalID
            )
        )
    }

    func clarifyPending(sessionID: String) async throws -> ClarificationPendingResponse {
        try await send(endpoint: .clarifyPending(sessionID: sessionID), method: "GET")
    }

    nonisolated func clarifyStreamURL(sessionID: String) -> URL {
        Endpoint.clarifyStream(sessionID: sessionID).url(relativeTo: baseURL)
    }

    func respondClarification(
        sessionID: String,
        response: String,
        clarifyID: String?
    ) async throws -> ClarificationRespondResponse {
        try await send(
            endpoint: .clarifyRespond,
            method: "POST",
            body: ClarificationRespondRequest(
                sessionId: sessionID,
                response: response,
                clarifyId: clarifyID
            )
        )
    }

    func steerChat(sessionID: String, text: String) async throws -> ChatSteerResponse {
        try await send(
            endpoint: .chatSteer,
            method: "POST",
            body: ChatSteerRequest(sessionId: sessionID, text: text)
        )
    }

    func submitGoal(
        sessionID: String,
        args: String,
        workspace: String?,
        model: String?,
        modelProvider: String?,
        profile: String?
    ) async throws -> GoalSubmissionResponse {
        try await send(
            endpoint: .submitGoal,
            method: "POST",
            body: GoalSubmissionRequest(
                sessionId: sessionID,
                args: args,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile
            )
        )
    }

    func startBtw(sessionID: String, question: String) async throws -> BtwStartResponse {
        try await send(
            endpoint: .btw,
            method: "POST",
            body: BtwRequest(sessionId: sessionID, question: question)
        )
    }

    func startBackground(sessionID: String, prompt: String) async throws -> BackgroundStartResponse {
        try await send(
            endpoint: .background,
            method: "POST",
            body: BackgroundRequest(sessionId: sessionID, prompt: prompt)
        )
    }

    func backgroundStatus(sessionID: String) async throws -> BackgroundStatusResponse {
        try await send(endpoint: .backgroundStatus(sessionID: sessionID), method: "GET")
    }
}

private struct ChatStartRequest: Encodable {
    let sessionId: String
    let message: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
    let explicitModelPick: Bool?
    let attachments: [JSONValue]?
}

private struct ChatSteerRequest: Encodable {
    let sessionId: String
    let text: String
}

private struct GoalSubmissionRequest: Encodable {
    let sessionId: String
    let args: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
}

private struct ApprovalRespondRequest: Encodable {
    let sessionId: String
    let choice: ApprovalChoice
    let approvalId: String?
}

private struct ClarificationRespondRequest: Encodable {
    let sessionId: String
    let response: String
    let clarifyId: String?
}

private struct BtwRequest: Encodable {
    let sessionId: String
    let question: String
}

private struct BackgroundRequest: Encodable {
    let sessionId: String
    let prompt: String
}
