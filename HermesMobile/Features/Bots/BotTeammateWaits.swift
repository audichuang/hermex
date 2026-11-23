import Foundation
import Observation

struct BotTeammateDelivery: Equatable, Identifiable {
    enum State: String { case queued, claimed, working, waitingOnYou = "waiting_on_you", failed }

    let id: String
    let target: String
    let targetHandle: String?
    let state: State
    let since: Date?
    let waitingOn: String?
    let reason: String?
    let error: String?

    var isUnknownOutcome: Bool { state == .failed && reason == "unknown_outcome" }
    var teammateName: String { Self.nonEmpty(targetHandle) ?? target }

    init?(_ json: BotJSON) {
        guard let id = Self.nonEmpty(json["delivery_id"].text),
              let state = json["state"].text.flatMap(State.init(rawValue:)) else { return nil }
        self.id = id
        self.state = state
        target = json["target"].text ?? ""
        targetHandle = json["target_handle"].text
        since = json["since"].number.map { Date(timeIntervalSince1970: $0) }
        waitingOn = json["waiting_on"].text
        reason = json["reason"].text
        error = json["error"].text
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    enum Label: Equatable {
        case queued, pickedUp, working, answerQuestion, approveOrDeny, outcomeUnknown
        case failed(FailureText)
    }

    enum FailureText: Equatable {
        case known(String)
        case verbatim(String)
        case unknown
    }

    static let knownReasons: Set<String> = [
        "provider_auth_or_access", "provider_quota_limit", "provider_rate_limit", "provider_server_error",
        "missing_config", "model_unavailable", "context_overflow", "runtime_offline", "queued_expired",
        "delivery_timeout", "agent_blocked", "cancelled",
    ]

    var label: Label {
        switch state {
        case .queued: return .queued
        case .claimed: return .pickedUp
        case .working: return .working
        case .waitingOnYou: return waitingOn == "approval" ? .approveOrDeny : .answerQuestion
        case .failed:
            if isUnknownOutcome { return .outcomeUnknown }
            if let reason, Self.knownReasons.contains(reason) { return .failed(.known(reason)) }
            if let error = Self.nonEmpty(error) { return .failed(.verbatim(error)) }
            return .failed(.unknown)
        }
    }
}

struct BotTeammateDismissedStore {
    var defaults: UserDefaults = .standard

    private func key(_ connectionID: UUID) -> String { "bot-teammate-dismissed." + connectionID.uuidString }

    func load(connectionID: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: key(connectionID)) ?? [])
    }

    func save(_ ids: Set<String>, connectionID: UUID) {
        defaults.set(ids.sorted(), forKey: key(connectionID))
    }
}

@MainActor @Observable final class BotTeammateWaits {
    static let pollInterval = Duration.seconds(5)

    private(set) var rows: [BotTeammateDelivery] = []
    private(set) var isStale = false
    private(set) var fetchedAt: Date?
    private(set) var isUnsupported = false
    private var dismissed: Set<String>

    @ObservationIgnored private let load: @MainActor () async throws -> BotJSON
    @ObservationIgnored private let store: BotTeammateDismissedStore
    @ObservationIgnored private let connectionID: UUID
    @ObservationIgnored private let now: () -> Date

    init(connectionID: UUID, store: BotTeammateDismissedStore = .init(), now: @escaping () -> Date = { Date() },
         load: @escaping @MainActor () async throws -> BotJSON) {
        self.connectionID = connectionID
        self.store = store
        self.now = now
        self.load = load
        dismissed = store.load(connectionID: connectionID)
    }

    var visibleRows: [BotTeammateDelivery] {
        rows.filter { !($0.state == .failed && dismissed.contains($0.id)) }
    }

    var showsNeverResent: Bool { visibleRows.contains(where: \.isUnknownOutcome) }

    func dismiss(_ id: String) {
        guard rows.first(where: { $0.id == id })?.state == .failed, dismissed.insert(id).inserted else { return }
        store.save(dismissed, connectionID: connectionID)
    }

    func refresh() async {
        guard !isUnsupported else { return }
        do {
            let reply = try await load()
            guard !Task.isCancelled else { return }
            let next = (reply["deliveries"].list ?? []).compactMap(BotTeammateDelivery.init)
            if next != rows { rows = next }
            if isStale { isStale = false }
            fetchedAt = now()
        } catch {
            guard !Task.isCancelled else { return }
            if Self.isMethodMissing(error) {
                rows = []
                isUnsupported = true
            } else if !isStale {
                isStale = true
            }
        }
    }

    func poll() async {
        while !Task.isCancelled, !isUnsupported {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func age(of row: BotTeammateDelivery) -> TimeInterval? {
        guard let since = row.since, let fetchedAt else { return nil }
        return max(0, fetchedAt.timeIntervalSince(since))
    }

    private static func isMethodMissing(_ error: Error) -> Bool {
        if error as? BotFailure == .rejected(-32601) { return true }
        if case BotSettingFailure.rejected(-32601, _) = error { return true }
        return false
    }
}
