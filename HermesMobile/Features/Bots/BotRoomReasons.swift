import Foundation

enum BotRoomReason {
    static func text(code: String?, detail: String? = nil) -> String? {
        if let mapped = mappedText(for: code) {
            return mapped
        }
        if let detailText = freeOrMappedText(from: detail) {
            return detailText
        }
        return freeOrMappedText(from: code)
    }

    private static func mappedText(for raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return label(for: trimmed)
    }

    private static func freeOrMappedText(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty else { return nil }
        if let mapped = label(for: firstLine) {
            return mapped
        }
        if firstLine == "member turn cancelled" || firstLine == "member turn failed" || isCodeShaped(firstLine) {
            return nil
        }
        return firstLine
    }

    private static func isCodeShaped(_ text: String) -> Bool {
        text.range(of: "\\A[A-Za-z][A-Za-z0-9_.:-]*\\z", options: .regularExpression) != nil
    }

    private static func label(for code: String) -> String? {
        switch code {
        case "member_unavailable": String(localized: "The bot is unavailable")
        case "runtime_offline": String(localized: "The bot is offline")
        case "queued_expired": String(localized: "The queued turn expired")
        case "delivery_timeout": String(localized: "The reply did not arrive in time")
        case "agent_blocked": String(localized: "The bot is blocked")
        case "cancelled": String(localized: "The turn was cancelled")
        case "provider_auth_or_access": String(localized: "The provider refused access")
        case "provider_quota_limit": String(localized: "The provider quota has been reached")
        case "provider_rate_limit", "rate_limited": String(localized: "The provider is receiving too many requests")
        case "provider_server_error": String(localized: "The provider encountered an error")
        case "context_overflow": String(localized: "The conversation is too long for the model")
        case "missing_config": String(localized: "Required settings are missing")
        case "model_unavailable": String(localized: "The selected model is unavailable")
        case "target_scope_unresolved": String(localized: "The bot could not access its credentials")
        case "superseded_by_newer_user_event": String(localized: "A newer message replaced this turn")
        case "turn_deadline_exceeded": String(localized: "The turn exceeded its time limit")
        case "prepare_failed": String(localized: "The bots could not be started")
        case "slot_wait_timeout": String(localized: "Too many bots are running")
        case "target_busy": String(localized: "The bot is busy")
        case "member gateway restarted": String(localized: "The bot’s gateway restarted")
        default: nil
        }
    }
}
