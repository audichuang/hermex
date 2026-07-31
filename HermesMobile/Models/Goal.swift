import Foundation

struct GoalSubmissionResponse: Decodable, Equatable {
    let ok: Bool?
    let action: String?
    let message: String?
    let goal: SubmittedGoal?
    let kickoffPrompt: String?
    let decision: GoalDecision?

    var displayMessage: String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var kickoffPromptText: String? {
        let trimmed = kickoffPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case action
        case message
        case goal
        case kickoffPrompt
        case kickoffPromptSnake = "kickoff_prompt"
        case decision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        action = container.decodeLossyStringIfPresent(forKey: .action)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        goal = try? container.decodeIfPresent(SubmittedGoal.self, forKey: .goal)
        kickoffPrompt = container.decodeLossyStringIfPresent(forKey: .kickoffPrompt)
            ?? container.decodeLossyStringIfPresent(forKey: .kickoffPromptSnake)
        decision = try? container.decodeIfPresent(GoalDecision.self, forKey: .decision)
    }
}

struct SubmittedGoal: Decodable, Equatable {
    let goal: String?
    let status: String?
    let turnsUsed: Int?
    let maxTurns: Int?
    let lastVerdict: String?
    let lastReason: String?
    let pausedReason: String?

    enum CodingKeys: String, CodingKey {
        case goal
        case status
        case turnsUsed
        case turnsUsedSnake = "turns_used"
        case maxTurns
        case maxTurnsSnake = "max_turns"
        case lastVerdict
        case lastVerdictSnake = "last_verdict"
        case lastReason
        case lastReasonSnake = "last_reason"
        case pausedReason
        case pausedReasonSnake = "paused_reason"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = container.decodeLossyStringIfPresent(forKey: .goal)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        turnsUsed = container.decodeLossyIntIfPresent(forKey: .turnsUsed)
            ?? container.decodeLossyIntIfPresent(forKey: .turnsUsedSnake)
        maxTurns = container.decodeLossyIntIfPresent(forKey: .maxTurns)
            ?? container.decodeLossyIntIfPresent(forKey: .maxTurnsSnake)
        lastVerdict = container.decodeLossyStringIfPresent(forKey: .lastVerdict)
            ?? container.decodeLossyStringIfPresent(forKey: .lastVerdictSnake)
        lastReason = container.decodeLossyStringIfPresent(forKey: .lastReason)
            ?? container.decodeLossyStringIfPresent(forKey: .lastReasonSnake)
        pausedReason = container.decodeLossyStringIfPresent(forKey: .pausedReason)
            ?? container.decodeLossyStringIfPresent(forKey: .pausedReasonSnake)
    }
}

/// Payload of the `goal` and `goal_continue` SSE frames emitted mid-turn by
/// `api/streaming.py` while a goal is driving the conversation.
///
/// The frames are not uniform, which is why every field here is optional:
/// - the first `goal` frame ("evaluating") carries only
///   `{session_id, state, message, message_key}` — no `decision`;
/// - a second `goal` frame follows only when the evaluation produced a message,
///   and that one does carry `decision` plus `state` of "continuing" / "idle";
/// - `goal_continue` carries the prompt that advances the goal one more turn,
///   sent as `continuation_prompt` and mirrored in `text`, and no `state`.
///
/// Other frames (`metering`, `title`, …) interleave with these before
/// `stream_end`, so nothing here may assume a fixed ordering.
///
/// Decoded by `SSEEventDecoder` with a plain `JSONDecoder`, so every key is
/// spelled out in snake_case rather than relying on a conversion strategy.
struct GoalStreamEvent: Decodable, Equatable {
    let sessionId: String?
    let state: String?
    let message: String?
    let messageKey: String?
    let continuationPrompt: String?
    let text: String?
    let decision: GoalDecision?

    /// The prompt to resend so the goal advances, or nil when this frame does
    /// not carry one. Upstream mirrors the value across `continuation_prompt`,
    /// `text`, and `decision.continuation_prompt`; any one of them is
    /// authoritative, and a blank value counts as absent.
    var continuationPromptText: String? {
        for candidate in [continuationPrompt, text, decision?.continuationPrompt] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state
        case message
        case messageKey = "message_key"
        case continuationPrompt = "continuation_prompt"
        case text
        case decision
    }

    init(
        sessionId: String? = nil,
        state: String? = nil,
        message: String? = nil,
        messageKey: String? = nil,
        continuationPrompt: String? = nil,
        text: String? = nil,
        decision: GoalDecision? = nil
    ) {
        self.sessionId = sessionId
        self.state = state
        self.message = message
        self.messageKey = messageKey
        self.continuationPrompt = continuationPrompt
        self.text = text
        self.decision = decision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        state = container.decodeLossyStringIfPresent(forKey: .state)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        messageKey = container.decodeLossyStringIfPresent(forKey: .messageKey)
        continuationPrompt = container.decodeLossyStringIfPresent(forKey: .continuationPrompt)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        decision = try? container.decodeIfPresent(GoalDecision.self, forKey: .decision)
    }
}

struct GoalDecision: Decodable, Equatable {
    let status: String?
    let shouldContinue: Bool?
    let continuationPrompt: String?
    let verdict: String?
    let reason: String?
    let message: String?
    let messageKey: String?
    let messageArgs: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case status
        case shouldContinue
        case shouldContinueSnake = "should_continue"
        case continuationPrompt
        case continuationPromptSnake = "continuation_prompt"
        case verdict
        case reason
        case message
        case messageKey
        case messageKeySnake = "message_key"
        case messageArgs
        case messageArgsSnake = "message_args"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        shouldContinue = container.decodeLossyBoolIfPresent(forKey: .shouldContinue)
            ?? container.decodeLossyBoolIfPresent(forKey: .shouldContinueSnake)
        continuationPrompt = container.decodeLossyStringIfPresent(forKey: .continuationPrompt)
            ?? container.decodeLossyStringIfPresent(forKey: .continuationPromptSnake)
        verdict = container.decodeLossyStringIfPresent(forKey: .verdict)
        reason = container.decodeLossyStringIfPresent(forKey: .reason)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        messageKey = container.decodeLossyStringIfPresent(forKey: .messageKey)
            ?? container.decodeLossyStringIfPresent(forKey: .messageKeySnake)
        messageArgs = (try? container.decodeIfPresent([JSONValue].self, forKey: .messageArgs))
            ?? (try? container.decodeIfPresent([JSONValue].self, forKey: .messageArgsSnake))
    }
}
