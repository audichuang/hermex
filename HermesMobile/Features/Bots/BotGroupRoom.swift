import Foundation

/// Room identity never borrows a display name or a hidden member session ID.
struct BotRoomKey: Hashable, Identifiable {
    let server: URL
    let connectionID: UUID
    let roomID: String
    var id: Self { self }
}

struct BotRoomCapabilities: Equatable {
    let enabled: Bool
    let authority: String?
    let pageLimit: Int
    let methods: Set<String>
    /// The Profiles a canonical host's `groups.create` will seat for this connection (#1605); nil
    /// from a dashboard, which names none and seats whoever its roster lists.
    let seatableProfiles: Set<String>?
    init(_ value: BotJSON) {
        let methods = Set(value["methods"].list?.compactMap(\.text) ?? [])
        self.methods = methods
        seatableProfiles = value["seatable_profiles"].list.map { Set($0.compactMap(\.text)) }
        enabled = value["driver"].flag == true && Set(["groups.list", "groups.state", "groups.log"]).isSubset(of: methods)
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

/// One live room task from `driver_status.member_activity`: who is answering, since when, and
/// (only when the host runs the turn itself) which tool it is in.
struct BotRoomMemberActivity: Equatable {
    enum Phase: Equatable { case queued, running, stopping }
    let memberID: String
    let phase: Phase
    let threadID: String?
    let startedAt: Date?
    let tool: String?
    /// The last frame the host saw; absent when another process runs the turn.
    let progressAt: Date?
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
    }
}

/// One round of a room discussion, condensed so the composer can show it on a single line:
/// who is on now, how far the round is, and what the members before them did. Built from the
/// log the reader already holds plus the live `member_activity` rows; nil when nothing runs.
struct BotRoomRound: Equatable {
    enum Outcome: Equatable { case waiting, queued, working, stopping, passed, replied, failed, cancelled }
    struct Seat: Equatable {
        let memberID: String
        let name: String
        var outcome: Outcome
    }

    /// The members this message reaches, finished ones first, in the order they ran.
    let seats: [Seat]
    /// Live rows of this round, running before queued.
    let live: [BotRoomMemberActivity]
    /// The lead is still choosing who takes an unaddressed message (`routing: lead`).
    let routingBy: String?

    var finished: Int { seats.filter { [.passed, .replied, .failed, .cancelled].contains($0.outcome) }.count }

    static func build(events: [BotRoomEvent], activity: [BotRoomMemberActivity], room: BotGroupRoom,
                      threadID: String?) -> BotRoomRound? {
        let rows = threadID.map { id in activity.filter { $0.threadID == id } } ?? activity
        guard !rows.isEmpty else { return nil }
        let live = rows.filter { $0.phase != .queued } + rows.filter { $0.phase == .queued }
        let thread = live.first?.threadID
        let message = events.last { $0.kind == "message.user" && $0.payload["thread_id"].text == thread }
        let discussion = message?.eventID
        let ofDiscussion = events.filter { discussion != nil && $0.payload["discussion_event_id"].text == discussion }
        func name(_ id: String) -> String { room.members.first { $0.id == id }?.name ?? id }

        // Who this message reaches: the lead's pick, else anyone it @mentions, else the whole room.
        var planned = room.members.map(\.id)
        let assigned = ofDiscussion.last { $0.kind == "room.assignment" }?.payload["member_ids"].list?.compactMap(\.text)
        let context = events.last { $0.kind == "room.context_set" }?.payload
        let text = message?.payload["text"].text ?? ""
        let mentioned = room.members.filter { member in
            member.handle.map { text.range(of: "@\($0)", options: .caseInsensitive) != nil } ?? false
        }.map(\.id)
        let broadcast = text.range(of: "@all", options: .caseInsensitive) != nil
            || text.range(of: "@everyone", options: .caseInsensitive) != nil
        var routingBy: String?
        if let assigned, !assigned.isEmpty {
            planned = assigned
        } else if !mentioned.isEmpty && !broadcast {
            planned = mentioned
        } else if context?["routing"].text == "lead", let lead = context?["lead_member_id"].text,
                  let message, events.first(where: { $0.payload["thread_id"].text == thread && $0.isMessage }) == message,
                  live.contains(where: { $0.memberID == lead }) {
            // A thread's first message goes to the lead alone until it names who takes it.
            routingBy = name(lead)
        }

        var outcomes: [String: Outcome] = [:]
        var order: [String] = []
        // The lead's routing turn settles under the assignment's task id: it chose who answers,
        // it did not pass on the message, so it takes no seat.
        let routingTasks = Set(ofDiscussion.filter { $0.kind == "room.assignment" }.compactMap { $0.payload["task_id"].text })
        for event in ofDiscussion {
            guard let member = event.payload["member_id"].text,
                  !routingTasks.contains(event.payload["task_id"].text ?? "") else { continue }
            let outcome: Outcome? = switch event.kind {
            case "turn.settled": event.payload["passed"].flag == true ? .passed : .replied
            case "turn.failed": .failed
            case "turn.cancelled": .cancelled
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
        return BotRoomRound(seats: routingBy == nil ? seats : [], live: live, routingBy: routingBy)
    }
}

struct BotRoomStatus: Equatable {
    let working: Bool
    let blocked: Bool
    let stopping: Int
    let stoppable: Int
    let actions: [BotRoomAction]
    /// Absent from older gateways, which leaves only the Stop button as a sign of work.
    let activity: [BotRoomMemberActivity]
    init(_ value: BotJSON) {
        activity = (value["member_activity"].list ?? []).compactMap(BotRoomMemberActivity.init)
        working = value["working"].flag == true
        blocked = value["blocked"].flag == true
        stopping = max(0, value["counts"]["stopping"].integer ?? 0)
        stoppable = max(0, value["counts"]["queued"].integer ?? 0) + max(0, value["counts"]["running"].integer ?? 0)
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

    /// True once the user or a member has said something. System rows such as
    /// a rename don't count, so a room renamed before its first message is new.
    static func hasConversation(in events: some Sequence<BotRoomEvent>) -> Bool {
        events.contains { ["message.user", "message.member"].contains($0.kind) }
    }
    var visible: Bool {
        ["message.user", "message.member", "turn.failed", "turn.cancelled", "room.stop_requested", "room.renamed"].contains(kind)
    }
    /// Read by the activity strip (`BotRoomRound`), never shown as transcript rows: the room's
    /// routing, whom the lead gave a message to, and which members already passed.
    var isRoundSignal: Bool { ["room.context_set", "room.assignment", "turn.settled"].contains(kind) }
    func member(in room: BotGroupRoom) -> BotGroupRoom.Member? {
        let id = payload["member_id"].text ?? actor["id"].text
        return room.members.first { $0.id == id }
    }
    func sender(in room: BotGroupRoom) -> String {
        actor["display_name"].text ?? member(in: room)?.name ?? actor["profile"].text ?? String(localized: "Bot")
    }
    var systemText: String {
        switch kind {
        case "turn.failed": return payload["error"].text.map { String(localized: "Failed: \($0)") } ?? String(localized: "Turn failed")
        case "turn.cancelled": return String(localized: "Turn cancelled")
        case "room.stop_requested": return String(localized: "Stop requested")
        case "room.renamed": return String(localized: "Room renamed to \(payload["name"].text ?? "")")
        default: return ""
        }
    }
}

/// A loaded projection, not a claim about the server's complete thread history.
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

/// Pure replay seam. Invisible events still advance the cursor and occupy their
/// sequence number. An unchanged page leaves the visible transcript untouched.
struct BotRoomLog {
    private(set) var cursor = 0
    private(set) var earlierBoundary = 0
    private(set) var events: [BotRoomEvent] = []
    /// Round signals (`isRoundSignal`) the transcript drops; the latest context is always kept.
    private(set) var signals: [BotRoomEvent] = []
    private var seen = Set<Int>()
    var hasRoutingContext: Bool { signals.contains { $0.kind == "room.context_set" } }
    static func windowStart(before sequence: Int) -> Int { max(0, sequence - 200) }
    /// Preserve system rows and the replay cursor without keeping an unbounded
    /// seen-set or the entire paged history alive after leaving the room.
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
    mutating func loadedEarlier(from start: Int) { earlierBoundary = start }
    /// An acknowledgment can arrive ahead of unread log events. Insert its bubble
    /// without skipping those events on the next log read.
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
    /// Takes only round signals from a page outside the loaded window (the room's first context),
    /// leaving the transcript, cursor and seen-set alone.
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

/// Room identifier, text and name rules shared by the room screens and
/// `HermesCall`'s room admission.
enum BotRoomRPC {
    static func validID(_ id: String) -> Bool {
        id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z", options: .regularExpression) != nil
    }
    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 64 * 1024
    }
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.unicodeScalars.count <= 200
    }
}

struct BotRoomFailure: Error, LocalizedError {
    let code: Int
    let reason: String?
    var expired: Bool { code == 4114 || reason == "room_history_expired" }
    var errorDescription: String? {
        if expired { return String(localized: "This room’s history is no longer available.") }
        if code == 4123 { return String(localized: "Restart the Hermes gateway on your Mac, then reconnect.") }
        // A canonical host refused a retry or discard because the task moved on (#1605).
        if reason == "stale_generation" { return String(localized: "This chat changed on the server. Reopen it and try again.") }
        return BotFailure.rejected(code).localizedDescription
    }
}
