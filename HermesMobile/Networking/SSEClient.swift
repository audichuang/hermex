import Foundation
import LDSwiftEventSource
import OSLog

@MainActor
protocol SSEStreamingClient: AnyObject {
    var lastEventID: String? { get }

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void)
    func stop()
}

@MainActor
final class SSEClient: SSEStreamingClient {
    private let baseConfiguration: URLSessionConfiguration
    private var eventSource: EventSource?
    /// Bumped on every `start` and `stop`, so a close callback can tell whether it
    /// belongs to the connection currently in use.
    private var connectionGeneration = 0
    private let reportsUnexpectedClose: Bool
    private(set) var lastEventID: String?
    /// Read at stream start so a new stream picks up the latest headers (#255).
    private let customHeaderProvider: @MainActor () -> [CustomHeader]

    /// `reportsUnexpectedClose` opts this client into surfacing a close it did not
    /// ask for as a `.transportError`.
    ///
    /// Off by default, and deliberately so. `LDSwiftEventSource` reconnects a clean
    /// EOF on its own, so reporting every close would turn that transparent recovery
    /// into an app-level error — which for the approval and clarification streams
    /// means dropping from SSE to fallback polling. Only the chat stream needs it,
    /// because only that stream's completion releases a held goal continuation: a
    /// lost terminal frame there would otherwise leave the composer wedged.
    init(
        urlSessionConfiguration: URLSessionConfiguration = .default,
        reportsUnexpectedClose: Bool = false,
        customHeaderProvider: @escaping @MainActor () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        baseConfiguration = urlSessionConfiguration
        self.reportsUnexpectedClose = reportsUnexpectedClose
        self.customHeaderProvider = customHeaderProvider
    }

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        stop()
        lastEventID = nil

        // Identifies this connection so a close callback from a previous one — or
        // from our own `stop()` — cannot be mistaken for this connection dropping.
        connectionGeneration += 1
        let generation = connectionGeneration

        let handler = SSEEventHandler(
            onEventID: { [weak self] eventID in
                self?.lastEventID = eventID
            },
            onEvent: onEvent,
            onUnexpectedClose: { [weak self] in
                // A close we did not ask for. Ignored unless this client opted in —
                // see `reportsUnexpectedClose`. For the chat stream a lost terminal
                // frame leaves a held goal continuation with nothing to release it,
                // so it has to hear about the close; routing it as a transport error
                // reuses the existing reconnect/finish handling rather than adding a
                // second recovery path.
                guard let self,
                      self.reportsUnexpectedClose,
                      self.connectionGeneration == generation
                else { return }
                onEvent(.transportError(String(localized: "The connection to the server closed unexpectedly.")))
            }
        )
        var config = EventSource.Config(handler: handler, url: url)
        config.connectionErrorHandler = { _ in .shutdown }
        // Custom headers merged underneath the built-ins so the built-ins win on
        // collision; an empty list leaves the built-in three unchanged (#255).
        config.headers = customHeaderProvider().merged(under: [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache, no-transform",
            "Accept-Encoding": "identity"
        ])

        let configuration = baseConfiguration.copy() as? URLSessionConfiguration ?? .default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlSessionConfiguration = configuration

        let source = EventSource(config: config)
        eventSource = source
        source.start()
    }

    func stop() {
        // Invalidate first: `stop()` triggers `onClosed`, and that close is expected.
        connectionGeneration += 1
        eventSource?.stop()
        eventSource = nil
    }
}

enum SSEEvent: Equatable {
    case token(String)
    case interimAssistant(InterimAssistantStreamEvent)
    case reasoning(String)
    case toolStarted(ToolStreamEvent)
    case toolCompleted(ToolStreamEvent)
    case title(TitleStreamEvent)
    case metering(MeteringStreamEvent)
    case done(DoneStreamEvent)
    /// Progress frame while a goal evaluates the turn just finished. Carries no
    /// action — it exists so a long evaluation counts as stream progress
    /// instead of looking stale.
    case goalStatus(GoalStreamEvent)
    /// The server decided the goal needs another turn and handed back the
    /// prompt for it. The client must start that turn; see
    /// `ChatViewModel.enqueueGoalContinuation`.
    case goalContinue(GoalStreamEvent)
    /// Auto-compression rotated the session id mid-stream. The client has to
    /// follow it or every later write lands in the archived parent snapshot.
    case sessionCompressed(SessionCompressedStreamEvent)
    case approvalPending(ApprovalPendingResponse)
    case clarificationPending(ClarificationPendingResponse)
    case pendingSteerLeftover(String)
    case streamEnd
    case cancelled
    case error(ErrorStreamEvent)
    /// Non-fatal: the stream continues. Never route this to `finishStream`.
    case warning(WarningStreamEvent)
    case transportError(String)
    case heartbeat
    case ignored
}

struct TitleStreamEvent: Decodable, Equatable {
    let sessionId: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
    }
}

struct ToolStreamEvent: Decodable, Equatable {
    let eventType: String?
    let name: String?
    let preview: String?
    let args: [String: JSONValue]?
    let duration: Double?
    let isError: Bool?
    let isCompleted: Bool?
    let stableID: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case name
        case preview
        case snippet
        case args
        case duration
        case isError = "is_error"
        case done
        case tid
        case id
        case toolCallID = "tool_call_id"
        case toolUseID = "tool_use_id"
        case callID = "call_id"
    }

    init(
        eventType: String?,
        name: String?,
        preview: String?,
        args: [String: JSONValue]?,
        duration: Double?,
        isError: Bool?,
        isCompleted: Bool? = nil,
        stableID: String? = nil
    ) {
        self.eventType = eventType
        self.name = name
        self.preview = preview
        self.args = args
        self.duration = duration
        self.isError = isError
        self.isCompleted = isCompleted
        self.stableID = stableID?.nonEmptyToolStreamID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = container.decodeLossyStringIfPresent(forKey: .eventType)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        preview = container.decodeLossyStringIfPresent(forKey: .snippet)
            ?? container.decodeLossyStringIfPresent(forKey: .preview)
        args = try? container.decodeIfPresent([String: JSONValue].self, forKey: .args)
        duration = container.decodeLossyDoubleIfPresent(forKey: .duration)
        isError = container.decodeLossyBoolIfPresent(forKey: .isError)
        isCompleted = container.decodeLossyBoolIfPresent(forKey: .done)
        stableID = [
            container.decodeLossyStringIfPresent(forKey: .tid),
            container.decodeLossyStringIfPresent(forKey: .id),
            container.decodeLossyStringIfPresent(forKey: .toolCallID),
            container.decodeLossyStringIfPresent(forKey: .toolUseID),
            container.decodeLossyStringIfPresent(forKey: .callID)
        ].compactMap { $0?.nonEmptyToolStreamID }.first
    }
}

struct InterimAssistantStreamEvent: Decodable, Equatable {
    let text: String?
    let alreadyStreamed: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case alreadyStreamed = "already_streamed"
    }

    init(text: String? = nil, alreadyStreamed: Bool? = nil) {
        self.text = text
        self.alreadyStreamed = alreadyStreamed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        alreadyStreamed = container.decodeLossyBoolIfPresent(forKey: .alreadyStreamed)
    }
}

struct MeteringStreamEvent: Decodable, Equatable {
    let tokensPerSecond: Double?
    let isTokensPerSecondAvailable: Bool?
    let isEstimated: Bool?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case tokensPerSecond = "tps"
        case isTokensPerSecondAvailable = "tps_available"
        case isEstimated = "estimated"
        case sessionId = "session_id"
    }

    init(
        tokensPerSecond: Double? = nil,
        isTokensPerSecondAvailable: Bool? = nil,
        isEstimated: Bool? = nil,
        sessionId: String? = nil
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.isTokensPerSecondAvailable = isTokensPerSecondAvailable
        self.isEstimated = isEstimated
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokensPerSecond = container.decodeLossyDoubleIfPresent(forKey: .tokensPerSecond)
        isTokensPerSecondAvailable = container.decodeLossyBoolIfPresent(forKey: .isTokensPerSecondAvailable)
        isEstimated = container.decodeLossyBoolIfPresent(forKey: .isEstimated)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
    }

    var displayableTokensPerSecond: Double? {
        guard isTokensPerSecondAvailable == true,
              isEstimated != true,
              let tokensPerSecond,
              tokensPerSecond.isFinite,
              tokensPerSecond > 0
        else {
            return nil
        }
        return tokensPerSecond
    }
}

struct SSEEventDecoder {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "SSEEventDecoder"
    )

    static func decode(eventType: String, data: String) -> SSEEvent {
        let eventData = Data(data.utf8)
        let decoder = JSONDecoder()

        switch eventType {
        case "token":
            let payload = decodePayload(TokenPayload.self, eventType: eventType, from: eventData, decoder: decoder)
            return .token(payload?.text ?? "")
        case "interim_assistant":
            let payload = decodePayload(
                InterimAssistantStreamEvent.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .interimAssistant(payload ?? InterimAssistantStreamEvent())
        case "reasoning":
            let payload = decodePayload(ReasoningPayload.self, eventType: eventType, from: eventData, decoder: decoder)
            return .reasoning(payload?.text ?? "")
        case "tool":
            let payload = decodePayload(ToolStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .toolStarted(payload ?? ToolStreamEvent())
        case "tool_complete":
            let payload = decodePayload(ToolStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .toolCompleted(payload ?? ToolStreamEvent())
        case "title":
            let payload = decodePayload(TitleStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .title(payload ?? TitleStreamEvent())
        case "metering":
            let payload = decodePayload(
                MeteringStreamEvent.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .metering(payload ?? MeteringStreamEvent())
        case "done":
            guard let payload = decodePayload(DonePayload.self, eventType: eventType, from: eventData, decoder: decoder) else {
                return .transportError("The stream returned a malformed completion event.")
            }
            return .done(payload.event)
        case "goal":
            let payload = decodePayload(GoalStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .goalStatus(payload ?? GoalStreamEvent())
        case "goal_continue":
            // Goal continuation is CLIENT-driven upstream: the server emits this
            // frame with the next prompt and marks the session pending, but never
            // starts the turn itself (see `static/messages.js`, which re-POSTs
            // /api/chat/start). A dropped frame therefore ends a multi-turn goal
            // after one turn, silently.
            let payload = decodePayload(GoalStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .goalContinue(payload ?? GoalStreamEvent())
        case "compressed":
            let payload = decodePayload(
                SessionCompressedStreamEvent.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .sessionCompressed(payload ?? SessionCompressedStreamEvent())
        case "initial":
            logInvalidJSONIfNeeded(eventType: eventType, payloadName: "pending stream payload", data: eventData)
            if ClarificationPendingResponse.containsClarificationMarkers(in: eventData) {
                return .clarificationPending(ClarificationPendingResponse.streamPayload(from: eventData, decoder: decoder))
            }
            return .approvalPending(ApprovalPendingResponse.streamPayload(from: eventData, decoder: decoder))
        case "approval":
            logInvalidJSONIfNeeded(eventType: eventType, payloadName: "approval stream payload", data: eventData)
            return .approvalPending(ApprovalPendingResponse.streamPayload(from: eventData, decoder: decoder))
        case "clarify":
            logInvalidJSONIfNeeded(eventType: eventType, payloadName: "clarification stream payload", data: eventData)
            return .clarificationPending(ClarificationPendingResponse.streamPayload(from: eventData, decoder: decoder))
        case "pending_steer_leftover":
            let payload = decodePayload(
                PendingSteerLeftoverPayload.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .pendingSteerLeftover(payload?.text ?? "")
        case "stream_end":
            return .streamEnd
        case "cancel":
            return .cancelled
        case "warning":
            let payload = decodePayload(
                WarningStreamEvent.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .warning(payload ?? WarningStreamEvent())
        case "error", "apperror":
            // "apperror" is one of the four socket-closing frames (stream_end, cancel,
            // error, apperror). The docs describe its payload as {error, type, session,
            // terminal_state?} while the pinned upstream emits {message, type, hint,
            // details, …}; `ErrorStreamEvent` decodes the union of both.
            guard let payload = decodePayload(ErrorStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder) else {
                return .error(ErrorStreamEvent(error: String(localized: "The stream returned a malformed error event.")))
            }
            return .error(payload)
        default:
            logger.debug("Ignoring unknown SSE event type '\(eventType, privacy: .public)'.")
            return .ignored
        }
    }

    private static func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        eventType: String,
        from data: Data,
        decoder: JSONDecoder
    ) -> Payload? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logDecodeFailure(eventType: eventType, payloadName: String(describing: type), error: error, data: data)
            return nil
        }
    }

    private static func logInvalidJSONIfNeeded(eventType: String, payloadName: String, data: Data) {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            logDecodeFailure(eventType: eventType, payloadName: payloadName, error: error, data: data)
        }
    }

    private static func logDecodeFailure(eventType: String, payloadName: String, error: Error, data: Data) {
        logger.debug(
            """
            Failed to decode SSE event '\(eventType, privacy: .public)' as \(payloadName, privacy: .public) \
            (\(data.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)
            """
        )
    }
}

private extension TitleStreamEvent {
    init() {
        sessionId = nil
        title = nil
    }
}

private extension ToolStreamEvent {
    init() {
        eventType = nil
        name = nil
        preview = nil
        args = nil
        duration = nil
        isError = nil
        isCompleted = nil
        stableID = nil
    }
}

private extension String {
    var nonEmptyToolStreamID: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class SSEEventHandler: EventHandler {
    private let onEventID: @MainActor (String) -> Void
    private let onEvent: @MainActor (SSEEvent) -> Void
    private let onUnexpectedClose: @MainActor () -> Void

    init(
        onEventID: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (SSEEvent) -> Void,
        onUnexpectedClose: @escaping @MainActor () -> Void = {}
    ) {
        self.onEventID = onEventID
        self.onEvent = onEvent
        self.onUnexpectedClose = onUnexpectedClose
    }

    func onOpened() {}

    func onClosed() {
        Task { @MainActor in
            onUnexpectedClose()
        }
    }

    func onMessage(eventType: String, messageEvent: MessageEvent) {
        let event = SSEEventDecoder.decode(eventType: eventType, data: messageEvent.data)

        Task { @MainActor in
            let eventID = messageEvent.lastEventId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !eventID.isEmpty {
                onEventID(eventID)
            }
            onEvent(event)
        }
    }

    func onComment(comment _: String) {
        Task { @MainActor in
            onEvent(.heartbeat)
        }
    }

    func onError(error: Error) {
        Task { @MainActor in
            onEvent(.transportError(error.localizedDescription))
        }
    }
}

private struct TokenPayload: Decodable {
    let text: String?
}

private struct ReasoningPayload: Decodable {
    let text: String?
}

/// The `error` / `apperror` payload.
///
/// Upstream sends far more than a message. `recovery_control` in particular is
/// not a user-facing error at all: it marks a frame whose only job is to make
/// the client rebuild its transcript (`api/run_journal.py:760`,
/// `api/routes.py:17461` @ 399cd7ab), and the web client answers it by
/// reloading without showing anything. `session` rides along because the error
/// path can also carry a compression rotation, and the error text has already
/// been appended to the stored transcript (`api/streaming.py:10195`), so a
/// reload is what actually surfaces it. Everything optional (#6).
struct ErrorStreamEvent: Decodable, Equatable {
    let error: String?
    let message: String?
    let type: String?
    let hint: String?
    let details: String?
    let terminalState: String?
    let recoveryControl: Bool?
    let session: SessionDetail?

    enum CodingKeys: String, CodingKey {
        case error, message, type, hint, details, session
        case terminalState = "terminal_state"
        case recoveryControl = "recovery_control"
    }

    init(
        error: String? = nil,
        message: String? = nil,
        type: String? = nil,
        hint: String? = nil,
        details: String? = nil,
        terminalState: String? = nil,
        recoveryControl: Bool? = nil,
        session: SessionDetail? = nil
    ) {
        self.error = error
        self.message = message
        self.type = type
        self.hint = hint
        self.details = details
        self.terminalState = terminalState
        self.recoveryControl = recoveryControl
        self.session = session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        hint = try? container.decodeIfPresent(String.self, forKey: .hint)
        details = container.decodeLossyStringIfPresent(forKey: .details)
        terminalState = try? container.decodeIfPresent(String.self, forKey: .terminalState)
        recoveryControl = try? container.decodeIfPresent(Bool.self, forKey: .recoveryControl)
        session = Self.decodeSession(from: container)
    }

    private static func decodeSession(from container: KeyedDecodingContainer<CodingKeys>) -> SessionDetail? {
        guard let value = try? container.decodeIfPresent(JSONValue.self, forKey: .session),
              let data = try? JSONEncoder().encode(value)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SessionDetail.self, from: data)
    }

    /// True when the frame exists to rebuild the transcript rather than to
    /// report something to the user.
    var isRecoveryControl: Bool { recoveryControl == true }

    /// The text to show, followed by distinct diagnostics and remediation.
    func displayMessage(fallback: String) -> String {
        let body = [error, message].compactMap(Self.nonEmpty).first ?? fallback
        var parts = [body]
        if let details = Self.nonEmpty(details),
           !Self.isProducerTruncation(details, of: body) {
            parts.append(details)
        }
        if let hint = Self.nonEmpty(hint), !parts.contains(hint) {
            parts.append(hint)
        }
        return parts.joined(separator: "\n")
    }

    private static func isProducerTruncation(_ details: String, of message: String) -> Bool {
        guard details != message, message.count > 1_200 else {
            return details == message
        }

        var expected = String(message.prefix(1_197))
        while expected.last?.isWhitespace == true {
            expected.removeLast()
        }
        return details == expected + "…"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A non-fatal `warning` frame. The stream keeps running, so this must never
/// reach `finishStream`. Upstream's main case is a rate-limited model being
/// swapped for a fallback (`api/streaming.py:8059` @ 399cd7ab), which the user
/// otherwise cannot see at all — they would judge the wrong model's quality and
/// cost (#7).
struct WarningStreamEvent: Decodable, Equatable {
    let type: String?
    let message: String?

    init(type: String? = nil, message: String? = nil) {
        self.type = type
        self.message = message
    }

    var displayMessage: String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }

        switch type {
        case "fallback":
            return String(localized: "The model was busy, so the server answered with its fallback model.")
        case "approval_gateway_unsupported", "approval_gateway_offline":
            return String(localized: "Approvals aren't available on this run, so the agent may act without asking.")
        default:
            return nil
        }
    }
}

/// The `compressed` frame an auto-compression turn emits
/// (`api/streaming.py:9781` @ 399cd7ab). Upstream rotates the session id in the
/// middle of the stream: the old id is archived as a `pre_compression_snapshot`
/// and the conversation continues under a new one, which `done.session` then
/// carries. Every field is optional — this frame is informational upstream and
/// its keys have already been renamed once.
struct SessionCompressedStreamEvent: Decodable, Equatable {
    let sessionId: String?
    let oldSessionId: String?
    let newSessionId: String?
    let continuationSessionId: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case oldSessionId = "old_session_id"
        case newSessionId = "new_session_id"
        case continuationSessionId = "continuation_session_id"
        case message
    }

    init(
        sessionId: String? = nil,
        oldSessionId: String? = nil,
        newSessionId: String? = nil,
        continuationSessionId: String? = nil,
        message: String? = nil
    ) {
        self.sessionId = sessionId
        self.oldSessionId = oldSessionId
        self.newSessionId = newSessionId
        self.continuationSessionId = continuationSessionId
        self.message = message
    }

    /// The id the conversation continues under, or nil when the frame names no
    /// usable one. `continuation_session_id` and `new_session_id` are the same
    /// value upstream today; preferring the explicit continuation keeps the
    /// client correct if they ever diverge.
    var continuedSessionID: String? {
        for candidate in [continuationSessionId, newSessionId] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

struct DoneStreamEvent: Equatable {
    let usage: ContextWindowSnapshot?
    let session: SessionDetail?

    init(usage: ContextWindowSnapshot? = nil, session: SessionDetail? = nil) {
        self.usage = usage
        self.session = session
    }
}

private struct DonePayload: Decodable {
    let event: DoneStreamEvent

    enum CodingKeys: String, CodingKey {
        case usage
        case session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = DoneStreamEvent(
            usage: try Self.decodeUsage(from: container),
            session: try Self.decodeSession(from: container)
        )
    }

    private static func decodeUsage(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ContextWindowSnapshot? {
        guard container.contains(.usage) else {
            return nil
        }

        return try container.decodeIfPresent(ContextWindowSnapshot.self, forKey: .usage)
    }

    private static func decodeSession(from container: KeyedDecodingContainer<CodingKeys>) throws -> SessionDetail? {
        guard container.contains(.session),
              let value = try container.decodeIfPresent(JSONValue.self, forKey: .session)
        else {
            return nil
        }

        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: data)
    }
}

private struct PendingSteerLeftoverPayload: Decodable {
    let text: String?
}
