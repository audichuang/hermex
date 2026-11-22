import Foundation

struct BotRoomMemberOutcome: Equatable {
    let kind: BotRoomRound.Outcome
    let reasonCode: String?
    let detail: String?

    init(kind: BotRoomRound.Outcome, reasonCode: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.reasonCode = reasonCode
        self.detail = detail
    }

    static func latest(in events: [BotRoomEvent]) -> [String: BotRoomMemberOutcome] {
        var discussions: [String: String] = [:]
        var routingTasks: [String: Set<String>] = [:]
        for event in events {
            if event.kind == "message.user", let id = event.eventID, !id.isEmpty {
                discussions[event.payload["thread_id"].text ?? ""] = id
            } else if event.kind == "room.assignment",
                      let discussion = event.payload["discussion_event_id"].text, !discussion.isEmpty,
                      let taskID = event.payload["task_id"].text, !taskID.isEmpty {
                routingTasks[discussion, default: []].insert(taskID)
            }
        }
        guard !discussions.isEmpty else { return [:] }

        var outcomes: [String: BotRoomMemberOutcome] = [:]
        for event in events {
            guard let memberID = event.payload["member_id"].text, !memberID.isEmpty else { continue }
            let thread = event.payload["thread_id"].text ?? ""
            guard let discussion = discussions[thread],
                  let eventDiscussion = event.payload["discussion_event_id"].text,
                  eventDiscussion == discussion else { continue }
            if let taskID = event.payload["task_id"].text, !taskID.isEmpty,
               routingTasks[discussion]?.contains(taskID) == true { continue }
            guard let outcome = outcome(for: event) else { continue }
            outcomes[memberID] = outcome
        }
        return outcomes
    }

    static func activeActivity(for memberID: String, in activity: [BotRoomMemberActivity]) -> BotRoomMemberActivity? {
        let rows = activity.filter { $0.memberID == memberID }
        return rows.first { $0.phase == .running }
            ?? rows.first { $0.phase == .stopping }
            ?? rows.first
    }

    static func statusText(activity: BotRoomMemberActivity?, outcome: BotRoomMemberOutcome?) -> String? {
        if let activity {
            switch activity.phase {
            case .running:
                if let tool = activity.tool?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
                    return String(localized: "Working · \(tool)")
                }
                return String(localized: "Working")
            case .queued:
                return String(localized: "Queued")
            case .stopping:
                return String(localized: "Stopping…")
            }
        }
        guard let outcome else { return nil }
        switch outcome.kind {
        case .failed:
            if let reason = BotRoomReason.text(code: outcome.reasonCode, detail: outcome.detail) {
                return String(localized: "Failed: \(reason)")
            }
            return String(localized: "Failed")
        case .unavailable:
            return String(localized: "No answer")
        case .cancelled:
            return String(localized: "Cancelled")
        case .replied:
            return String(localized: "Replied")
        case .passed:
            return String(localized: "Skipped")
        case .waiting, .queued, .working, .stopping:
            return nil
        }
    }

    private static func outcome(for event: BotRoomEvent) -> BotRoomMemberOutcome? {
        switch event.kind {
        case "turn.settled":
            return BotRoomMemberOutcome(kind: event.payload["passed"].flag == true ? .passed : .replied)
        case "turn.failed":
            return BotRoomMemberOutcome(kind: .failed,
                                        reasonCode: event.payload["reason_code"].text,
                                        detail: event.payload["error"].text)
        case "turn.cancelled":
            return BotRoomMemberOutcome(kind: .cancelled)
        case "turn.deferred" where event.payload["reason"].text == "member_unavailable":
            return BotRoomMemberOutcome(kind: .unavailable)
        default:
            return nil
        }
    }
}
