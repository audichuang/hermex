import Foundation

extension BotRoomFailure {
    var ownerDidNotAnswer: Bool { code == 5124 }

    var explanation: String? {
        if reason == "runtime_coordination_required" || code == 4123 {
            return String(localized: "Restart the Hermes gateway on your Mac, then reconnect.")
        }
        return switch reason {
        case "session_busy":
            String(localized: "A member is still finishing work. Try again in a moment.")
        case "unknown_execution":
            String(localized: "This member’s work is no longer available. Reopen the room to see its current state.")
        case "stale_generation":
            String(localized: "This chat changed on the server. Reopen it and try again.")
        case "peer_unreachable":
            String(localized: "Couldn’t reach a member’s Hermes gateway. Check that it’s online, then try again.")
        case "unsupported_operation":
            String(localized: "A member’s Hermes gateway doesn’t support this action. Update it and try again.")
        case "room_stop_pending":
            String(localized: "This group is still stopping. Wait for it to finish, then try disbanding again.")
        case "room_disbanding_retry":
            String(localized: "Disbanding is already in progress. Try again in a moment.")
        case "member_home_unknown":
            String(localized: "Hermes can’t find a member’s gateway. Check the member’s connection before trying again.")
        case "peer_revoke_unsupported":
            String(localized: "A member’s Hermes gateway doesn’t support leaving this group. Update it and try disbanding again.")
        case "room approval is no longer pending":
            String(localized: "This approval is no longer needed.")
        default:
            nil
        }
    }
}
