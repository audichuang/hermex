import Foundation

struct BotRoomKey: Hashable, Identifiable {
    let server: URL
    let connectionID: UUID
    let roomID: String
    var id: Self { self }
}

struct BotRoomCapabilities: Equatable {
    let readable: Bool
    let enabled: Bool
    let authority: String?
    let pageLimit: Int
    let methods: Set<String>
    let seatableProfiles: Set<String>?
    init(_ value: BotJSON) {
        let methods = Set(value["methods"].list?.compactMap(\.text) ?? [])
        self.methods = methods
        seatableProfiles = value["seatable_profiles"].list.map { Set($0.compactMap(\.text)) }
        readable = Set(["groups.list", "groups.state", "groups.log"]).isSubset(of: methods)
        enabled = readable && value["driver"].flag == true
        authority = value["authority_gateway_id"].text
        pageLimit = min(200, max(1, value["max_log_limit"].integer ?? 200))
    }
}

struct BotGroupRoom: Hashable {
    struct Member: Hashable, Identifiable {
        let id: String
        let profile: String?
        let displayName: String?
        let handle: String?
        var name: String { displayName ?? handle ?? profile ?? id }
        init?(_ value: BotJSON) {
            guard let id = value["member_id"].text else { return nil }
            self.id = id; profile = value["profile"].text
            displayName = value["display_name"].text; handle = value["handle"].text
        }
    }
    let id: String
    let name: String
    let members: [Member]
    let updatedAt: Date?
    let latestSeq: Int
    let authority: String?
    let epoch: Int?
    let disbanded: Bool
    init?(_ value: BotJSON) {
        guard let id = value["room_id"].text, BotRoomRPC.validID(id) else { return nil }
        self.id = id; name = value["name"].text ?? id
        members = value["members"].list?.compactMap(Member.init) ?? []
        updatedAt = value["updated_at"].number.map(Date.init(timeIntervalSince1970:))
        latestSeq = max(0, value["latest_seq"].integer ?? 0)
        authority = value["authority_gateway_id"].text; epoch = value["authority_epoch"].integer
        disbanded = value["disbanded_at"] != .null
    }
    func isForeign(to authority: String?) -> Bool {
        guard let authority, let owner = self.authority else { return false }
        return owner != authority
    }
}

struct BotRoomMemberActivity: Equatable {
    enum Phase: Equatable { case queued, running, stopping }
    let memberID: String
    let phase: Phase
    let threadID: String?
    let startedAt: Date?
    let tool: String?
    let progressAt: Date?
    let roundIndex: Int?
    init?(_ value: BotJSON) {
        guard let memberID = value["member_id"].text, !memberID.isEmpty else { return nil }
        switch value["status"].text {
        case "queued": phase = .queued
        case "stopping": phase = .stopping
        default: phase = .running
        }
        self.memberID = memberID
        threadID = value["thread_id"].text
        startedAt = value["started_at"].number.map(Date.init(timeIntervalSince1970:))
        tool = value["tool"].text.flatMap { $0.isEmpty ? nil : $0 }
        progressAt = value["progress_at"].number.map(Date.init(timeIntervalSince1970:))
        roundIndex = value["round_index"].integer.flatMap { $0 >= 0 ? $0 : nil }
    }
}

struct BotRoomRound: Equatable {
    enum Outcome: Equatable { case waiting, queued, working, stopping, passed, replied, failed, cancelled, unavailable }
    struct Seat: Equatable {
        let memberID: String
        let name: String
        var outcome: Outcome
    }

    let seats: [Seat]
    let live: [BotRoomMemberActivity]
    let routingBy: String?
    let roundNumber: Int?
    let maxRounds: Int?

    var finished: Int { seats.filter { [.passed, .replied, .failed, .cancelled, .unavailable].contains($0.outcome) }.count }

    static func build(events: [BotRoomEvent], activity: [BotRoomMemberActivity], room: BotGroupRoom,
                      threadID: String?, context: BotRoomContext? = nil, maxRounds: Int? = nil) -> BotRoomRound? {
        let rows = threadID.map { id in activity.filter { $0.threadID == id } } ?? activity
        guard !rows.isEmpty else { return nil }
        let live = rows.filter { $0.phase != .queued } + rows.filter { $0.phase == .queued }
        let thread = live.first?.threadID
        let message = events.last { $0.kind == "message.user" && $0.payload["thread_id"].text == thread }
        let discussion = message?.eventID
        let ofDiscussion = events.filter { discussion != nil && $0.payload["discussion_event_id"].text == discussion }
        func name(_ id: String) -> String { room.members.first { $0.id == id }?.name ?? id }

        var planned = room.members.map(\.id)
        let assigned = ofDiscussion.last { $0.kind == "room.assignment" }?.payload["member_ids"].list?.compactMap(\.text)
        let routed = ofDiscussion.last { $0.kind == "room.routed" }?.payload
        let routingContext = context ?? events.last { $0.kind == "room.context_set" }.flatMap { BotRoomContext($0.payload) }
        let text = message?.payload["text"].text ?? ""
        let mentioned = room.members.filter { member in
            member.handle.map { text.range(of: "@\($0)", options: .caseInsensitive) != nil } ?? false
        }.map(\.id)
        let broadcast = text.range(of: "@all", options: .caseInsensitive) != nil
            || text.range(of: "@everyone", options: .caseInsensitive) != nil
        var routingBy: String?
        if let assigned, !assigned.isEmpty {
            planned = assigned
        } else if let routed {
            if routed["everyone"].flag == true {
                planned = room.members.map(\.id)
            } else if let picked = routed["member_ids"].list?.compactMap(\.text), !picked.isEmpty {
                planned = picked
            }
        } else if !mentioned.isEmpty && !broadcast {
            planned = mentioned
        } else if routingContext?.routing == "lead", let lead = routingContext?.leadMemberID,
                  let message, events.first(where: { $0.payload["thread_id"].text == thread && $0.isMessage }) == message,
                  live.contains(where: { $0.memberID == lead }) {
            routingBy = name(lead)
        }

        var outcomes: [String: Outcome] = [:]
        var order: [String] = []
        let routingTasks = Set(ofDiscussion.filter { $0.kind == "room.assignment" }.compactMap { $0.payload["task_id"].text })
        for event in ofDiscussion {
            guard let member = event.payload["member_id"].text,
                  !routingTasks.contains(event.payload["task_id"].text ?? "") else { continue }
            let outcome: Outcome? = switch event.kind {
            case "turn.settled": event.payload["passed"].flag == true ? .passed : .replied
            case "turn.failed": .failed
            case "turn.cancelled": .cancelled
            case "turn.deferred" where event.payload["reason"].text == "member_unavailable": .unavailable
            default: nil
            }
            guard let outcome else { continue }
            if outcomes[member] == nil { order.append(member) }
            outcomes[member] = outcome
        }
        for row in live {
            outcomes[row.memberID] = switch row.phase {
            case .running: .working
            case .queued: .queued
            case .stopping: .stopping
            }
            if !order.contains(row.memberID) { order.append(row.memberID) }
        }
        let seats = (order + planned.filter { !order.contains($0) }).map {
            Seat(memberID: $0, name: name($0), outcome: outcomes[$0] ?? .waiting)
        }
        let owningRounds = live.filter { $0.threadID == thread }.compactMap(\.roundIndex)
        let roundNumber = routingBy == nil ? owningRounds.max().map { $0 + 1 } : nil
        let resolvedMaxRounds = maxRounds.flatMap { $0 > 0 ? $0 : nil }
        return BotRoomRound(seats: routingBy == nil ? seats : [], live: live, routingBy: routingBy,
                            roundNumber: roundNumber, maxRounds: resolvedMaxRounds)
    }
}

struct BotRoomStatus: Equatable {
    let working: Bool
    let blocked: Bool
    let stopping: Int
    let stoppable: Int
    let maxContinues: Int?
    let maxRounds: Int?
    let actions: [BotRoomAction]
    let activity: [BotRoomMemberActivity]
    let routingModes: Set<String>
    init(_ value: BotJSON) {
        activity = (value["member_activity"].list ?? []).compactMap(BotRoomMemberActivity.init)
        working = value["working"].flag == true
        blocked = value["blocked"].flag == true
        stopping = max(0, value["counts"]["stopping"].integer ?? 0)
        stoppable = max(0, value["counts"]["queued"].integer ?? 0) + max(0, value["counts"]["running"].integer ?? 0)
        maxContinues = value["max_continues"].integer
        maxRounds = value["max_rounds"].integer.flatMap { $0 > 0 ? $0 : nil }
        routingModes = Set(value["routing_modes"].list?.compactMap(\.text) ?? [])
        actions = (value["pending_actions"].list ?? []).map(BotRoomAction.init)
    }
    var interval: Duration { working || blocked || stopping > 0 ? .seconds(2) : .seconds(10) }
}

struct BotRoomEvent: Identifiable, Equatable {
    let seq: Int
    let eventID: String?
    let kind: String
    let actor: BotJSON
    let payload: BotJSON
    let timestamp: Double?
    var id: Int { seq }
    init?(_ value: BotJSON) {
        guard let seq = value["seq"].integer, seq > 0 else { return nil }
        self.seq = seq; eventID = value["event_id"].text; kind = value["kind"].text ?? ""
        actor = value["actor"]; payload = value["payload"]; timestamp = value["created_at"].number
    }
    var threadID: String? {
        guard let id = payload["thread_id"].text, BotRoomRPC.validID(id) else { return nil }
        return id
    }
    var isMessage: Bool { kind == "message.user" || kind == "message.member" }
    var isBoundedActivity: Bool { kind == "room.activity" && payload["status"].text == "bounded" }

    static func hasConversation(in events: some Sequence<BotRoomEvent>) -> Bool {
        events.contains { ["message.user", "message.member"].contains($0.kind) }
    }
    var visible: Bool {
        isBoundedActivity || ["message.user", "message.member", "turn.failed", "turn.cancelled",
                              "turn.deferred", "member.unavailable",
                              "room.stop_requested", "room.renamed", "room.continued",
                              "room.assignment", "room.routed"].contains(kind)
    }
    var isRoundSignal: Bool { ["room.context_set", "turn.settled"].contains(kind) }
    func member(in room: BotGroupRoom) -> BotGroupRoom.Member? {
        let id = payload["member_id"].text ?? actor["id"].text
        return room.members.first { $0.id == id }
    }
    private func memberName(in room: BotGroupRoom) -> String? {
        let name = member(in: room)?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }
    func sender(in room: BotGroupRoom) -> String {
        actor["display_name"].text ?? member(in: room)?.name ?? actor["profile"].text ?? String(localized: "Bot")
    }
    func systemText(in room: BotGroupRoom) -> String {
        switch kind {
        case "turn.failed":
            let name = memberName(in: room)
            let reason = BotRoomReason.text(code: payload["reason_code"].text, detail: payload["error"].text)
            switch (name, reason) {
            case (let name?, let reason?): return String(localized: "\(name) failed: \(reason)")
            case (let name?, nil): return String(localized: "\(name) failed")
            case (nil, let reason?): return String(localized: "Failed: \(reason)")
            case (nil, nil): return String(localized: "Turn failed")
            }
        case "turn.cancelled":
            let name = memberName(in: room)
            let reason = BotRoomReason.text(code: payload["reason"].text, detail: payload["reason"].text)
            switch (name, reason) {
            case (let name?, let reason?): return String(localized: "\(name) cancelled: \(reason)")
            case (let name?, nil): return String(localized: "\(name) cancelled")
            case (nil, let reason?): return String(localized: "Turn cancelled: \(reason)")
            case (nil, nil): return String(localized: "Turn cancelled")
            }
        case "turn.deferred":
            let name = memberName(in: room)
            let rawReason = payload["reason"].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawReason == "member_unavailable" {
                if let name { return String(localized: "\(name) didn’t answer in time") }
                return String(localized: "The bot didn’t answer in time")
            }
            let reason = BotRoomReason.text(code: rawReason, detail: rawReason)
            switch (name, reason) {
            case (let name?, let reason?): return String(localized: "\(name) deferred: \(reason)")
            case (let name?, nil): return String(localized: "\(name) deferred")
            case (nil, let reason?): return String(localized: "Turn deferred: \(reason)")
            case (nil, nil): return String(localized: "Turn deferred")
            }
        case "member.unavailable":
            let code = payload["reason_code"].text ?? payload["reason"].text
            let reason = BotRoomReason.text(code: nil, detail: payload["error"].text)
                ?? BotRoomReason.text(code: code)
            if let reason { return String(localized: "Member unavailable: \(reason)") }
            return String(localized: "Member unavailable")
        case "room.stop_requested": return String(localized: "Stop requested")
        case "room.continued": return String(localized: "Discussion continued")
        case "room.activity" where isBoundedActivity: return String(localized: "Work limit reached")
        case "room.renamed": return String(localized: "Room renamed to \(payload["name"].text ?? "")")
        default: return ""
        }
    }
}

struct BotRoomThread: Identifiable, Equatable {
    let id: String
    let events: [BotRoomEvent]
    let historyIsPartial: Bool
    var messages: [BotRoomEvent] { events.filter(\.isMessage) }
    var root: BotRoomEvent? {
        guard !historyIsPartial, let first = messages.first, first.kind == "message.user" else { return nil }
        return first
    }
    var replyCount: Int { messages.count - (root == nil ? 0 : 1) }
    var latest: BotRoomEvent { events[events.count - 1] }

    static func group(_ events: [BotRoomEvent], hasEarlier: Bool) -> [Self] {
        var groups: [String: [BotRoomEvent]] = [:]
        for event in events {
            if let id = event.threadID { groups[id, default: []].append(event) }
        }
        return groups.map { Self(id: $0.key, events: $0.value, historyIsPartial: hasEarlier) }
            .sorted { $0.latest.seq > $1.latest.seq }
    }
}

struct BotRoomLog {
    private(set) var cursor = 0
    private(set) var earlierBoundary = 0
    private(set) var events: [BotRoomEvent] = []
    private(set) var signals: [BotRoomEvent] = []
    private var seen = Set<Int>()
    var hasRoutingContext: Bool { signals.contains { $0.kind == "room.context_set" } }
    static func windowStart(before sequence: Int) -> Int { max(0, sequence - 200) }
    func recentWindow() -> Self {
        var result = self
        result.events = Array(events.suffix(500))
        if events.count > 500, let first = result.events.first {
            result.earlierBoundary = max(earlierBoundary, first.seq - 1)
        }
        result.seen = Set(result.events.map(\.seq))
        return result
    }
    mutating func begin(latest: Int) {
        self = Self(); cursor = Self.windowStart(before: latest); earlierBoundary = cursor
    }
    mutating func rewind(to sequence: Int) {
        events.removeAll { $0.seq > sequence }
        signals.removeAll { $0.seq > sequence }
        seen = seen.filter { $0 <= sequence }
        cursor = sequence
        earlierBoundary = min(earlierBoundary, sequence)
    }
    mutating func loadedEarlier(from start: Int) { earlierBoundary = start }
    mutating func acknowledge(_ event: BotJSON) {
        let previous = cursor
        apply(.object(["events": .array([event])]))
        cursor = previous
    }
    mutating func apply(_ page: BotJSON) {
        let fresh = (page["events"].list ?? []).compactMap(BotRoomEvent.init).filter { seen.insert($0.seq).inserted }
        cursor = max(cursor, page["cursor"].integer ?? 0, fresh.map(\.seq).max() ?? 0)
        let visible = fresh.filter(\.visible)
        if !visible.isEmpty { events = (events + visible).sorted { $0.seq < $1.seq } }
        keepSignals(fresh)
    }
    mutating func applySignals(_ page: BotJSON) {
        let known = Set(signals.map(\.seq))
        keepSignals((page["events"].list ?? []).compactMap(BotRoomEvent.init).filter { !known.contains($0.seq) })
    }
    private mutating func keepSignals(_ fresh: [BotRoomEvent]) {
        let signal = fresh.filter(\.isRoundSignal)
        guard !signal.isEmpty else { return }
        var kept = (signals + signal).sorted { $0.seq < $1.seq }
        if kept.count > 300 {
            let context = kept.last { $0.kind == "room.context_set" }
            kept = Array(kept.suffix(300))
            if let context, !kept.contains(context) { kept.insert(context, at: 0) }
        }
        signals = kept
    }
}

enum BotRoomRPC {
    static func validID(_ id: String) -> Bool {
        id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z", options: .regularExpression) != nil
    }
    static func validText(_ text: String, attachments: Int = 0) -> Bool {
        (attachments > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && text.utf8.count <= 64 * 1024
    }
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.unicodeScalars.count <= 200
    }
}

struct BotRoomFailure: Error, LocalizedError {
    let code: Int
    let reason: String?
    let admitted: Bool?
    let message: String?

    init(code: Int, reason: String?, admitted: Bool? = nil, message: String? = nil) {
        self.code = code
        self.reason = reason
        self.admitted = admitted
        self.message = message
    }

    var expired: Bool { code == 4114 || reason == "room_history_expired" }
    var rejectsSendBeforeAdmission: Bool { reason == "invalid_params" || (code == 5112 && admitted == false) }
    var errorDescription: String? {
        if let explanation { return explanation }
        if expired { return String(localized: "This room’s history is no longer available.") }
        return message ?? BotFailure.rejected(code).localizedDescription
    }
}
