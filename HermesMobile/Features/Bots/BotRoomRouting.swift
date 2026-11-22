import Foundation

extension BotRoomEvent {
    var isRoutingEvent: Bool { kind == "room.assignment" || kind == "room.routed" }

    func routingText(in room: BotGroupRoom) -> String? {
        let roster = Dictionary(room.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        switch kind {
        case "room.assignment":
            guard let leadID = payload["lead_member_id"].text, !leadID.isEmpty else { return nil }
            let lead = roster[leadID]?.name ?? leadID
            if payload["fallback"].flag == true {
                return String(localized: "\(lead) is taking this")
            }
            let chosen = (payload["member_ids"].list?.compactMap(\.text) ?? [])
                .filter { !$0.isEmpty }
                .map { roster[$0]?.name ?? $0 }
            guard !chosen.isEmpty else { return nil }
            let names = chosen.formatted(.list(type: .and))
            return String(localized: "\(lead) gave this to \(names)")
        case "room.routed":
            if payload["fallback"].flag == true {
                return String(localized: "Couldn’t choose who answers, so everyone will")
            }
            if payload["everyone"].flag == true {
                return String(localized: "Assigned to everyone")
            }
            let names = (payload["member_ids"].list?.compactMap(\.text) ?? []).compactMap { roster[$0]?.name }
            guard !names.isEmpty else { return nil }
            return String(localized: "Assigned to \(names.formatted(.list(type: .and)))")
        default:
            return nil
        }
    }
}

struct BotRoomHandoff: Equatable, Hashable {
    let afterSeq: Int
    let from: String
    let to: String

    func text(in room: BotGroupRoom) -> String {
        let fromName = room.members.first { $0.id == from }?.name ?? from
        let toName = room.members.first { $0.id == to }?.name ?? to
        return String(localized: "\(fromName) asked \(toName)")
    }
}

enum BotRoomHandoffs {
    private static let terminalKinds: Set<String> = ["turn.settled", "turn.failed", "turn.cancelled", "turn.deferred"]

    private struct TurnKey: Hashable {
        let memberID: String
        let discussionID: String
    }

    static func find(in events: [BotRoomEvent], members: [BotGroupRoom.Member]) -> [Int: [BotRoomHandoff]] {
        var lastTurn: [TurnKey: Int] = [:]
        for event in events {
            guard terminalKinds.contains(event.kind),
                  let memberID = event.payload["member_id"].text, !memberID.isEmpty,
                  let discussionID = event.payload["discussion_event_id"].text, !discussionID.isEmpty else { continue }
            let key = TurnKey(memberID: memberID, discussionID: discussionID)
            lastTurn[key] = max(lastTurn[key] ?? 0, event.seq)
        }
        guard !lastTurn.isEmpty else { return [:] }

        var seenMembers: Set<String> = []
        let addressable = members.compactMap { member -> (id: String, handle: String)? in
            guard let handle = member.handle, !handle.isEmpty, seenMembers.insert(member.id).inserted else { return nil }
            return (member.id, handle)
        }
        guard !addressable.isEmpty else { return [:] }

        var result: [Int: [BotRoomHandoff]] = [:]
        for event in events where event.kind == "message.member" {
            guard let from = event.payload["member_id"].text ?? event.actor["id"].text, !from.isEmpty,
                  let discussionID = event.payload["discussion_event_id"].text, !discussionID.isEmpty,
                  let text = event.payload["text"].text ?? event.payload["content"].text, !text.isEmpty else { continue }
            var after: [BotRoomHandoff] = []
            for member in addressable where member.id != from {
                guard let turnSeq = lastTurn[TurnKey(memberID: member.id, discussionID: discussionID)],
                      turnSeq > event.seq,
                      mentions(member.handle, in: text) else { continue }
                after.append(BotRoomHandoff(afterSeq: event.seq, from: from, to: member.id))
            }
            if !after.isEmpty { result[event.seq] = after }
        }
        return result
    }

    static func mentions(_ handle: String, in text: String) -> Bool {
        guard !handle.isEmpty else { return false }
        let needle = "@\(handle)"
        var searchStart = text.startIndex
        while let range = text.range(of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == text.startIndex {
                beforeOK = true
            } else {
                let previous = text[text.index(before: range.lowerBound)]
                beforeOK = !isASCIIWord(previous) && previous != "@"
            }
            let afterOK: Bool
            if range.upperBound == text.endIndex {
                afterOK = true
            } else {
                let next = text[range.upperBound]
                afterOK = !isASCIIWord(next) && next != "-"
            }
            if beforeOK && afterOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isASCIIWord(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (ascii >= 48 && ascii <= 57)
            || (ascii >= 65 && ascii <= 90)
            || (ascii >= 97 && ascii <= 122)
            || ascii == 95
    }
}
