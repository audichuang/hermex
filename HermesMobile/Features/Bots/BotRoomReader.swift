import CryptoKit
import Foundation
import Observation
import OSLog

enum BotRoomPrimaryAction: Equatable {
    case send(enabled: Bool)
    case retry(enabled: Bool)
}

enum BotRoomStopControl: Equatable {
    case stop(enabled: Bool)
    case stopping
}

@MainActor @Observable final class BotRoomReader {
    enum Link: Equatable { case idle, connecting, live, stopped }
    let key: BotRoomKey
    let connection: BotConnection
    let initialSequence: Int?
    @ObservationIgnored private let cache: BotHistoryCache
    @ObservationIgnored private let draftStore: BotRoomDraftStore
    @ObservationIgnored private let draftGeneration: UUID
    @ObservationIgnored private(set) var historyRemoval: Task<Void, Never>?
    private(set) var room: BotGroupRoom
    private(set) var events: [BotRoomEvent] = []
    private(set) var roundEvents: [BotRoomEvent] = []
    private(set) var pauses: [Int: BotRoomPause] = [:]
    private(set) var pausedThreadIDs: Set<String> = []
    private(set) var handoffs: [Int: [BotRoomHandoff]] = [:]
    private(set) var memberOutcomes: [String: BotRoomMemberOutcome] = [:]
    private(set) var attachmentLists: [Int: BotRoomAttachmentList] = [:]
    @ObservationIgnored private let attachmentPreviews = BotRoomPreviewQueue()
    @ObservationIgnored private var sentAt: ContinuousClock.Instant?
    private(set) var status = BotRoomStatus(.null)
    private(set) var runtimeDown = false
    private(set) var context: BotRoomContext?
    private(set) var link = Link.idle
    private(set) var errorMessage: String?
    private(set) var needsSignIn = false
    private(set) var hasEarlier = false
    private(set) var loadingEarlier = false
    private(set) var foreignAuthority = false
    private var drafts: [String: String] = [:]
    private var replyTargets: [String: BotRoomReplyTarget] = [:]
    @ObservationIgnored private var insertedReplyHandles: [String: String] = [:]
    private var dictatingThreads: Set<String> = []
    private var attachmentDrafts: [String: [BotRoomAttachmentChip]] = [:]
    private var attachmentNotices: [String: String] = [:]
    @ObservationIgnored private let attachmentNow: () -> Date
    private var uncertainSends: [Send] = []
    private(set) var threads: [BotRoomThread] = []
    var draft: String {
        get { draft(in: nil) }
        set { setDraft(newValue, in: nil) }
    }
    func draft(in threadID: String?) -> String { drafts[threadID ?? ""] ?? "" }
    func setDraft(_ text: String, in threadID: String?) {
        let context = threadID ?? ""
        guard draft(in: threadID) != text else { return }
        drafts[context] = text.isEmpty ? nil : text
        if let inserted = insertedReplyHandles[context],
           !BotRoomReplyTarget.startsWithMention(inserted, in: text) {
            insertedReplyHandles[context] = nil
        }
        if let handle = replyTargets[context]?.handle,
           !BotRoomReplyTarget.startsWithMention(handle, in: text) {
            replyTargets[context] = nil
        }
        persistDrafts()
    }
    func setDictating(_ dictating: Bool, in threadID: String?) {
        let context = threadID ?? ""
        if dictating {
            if !dictatingThreads.contains(context) { dictatingThreads.insert(context) }
        } else if dictatingThreads.contains(context) {
            dictatingThreads.remove(context)
        }
    }
    func replyTarget(in threadID: String?) -> BotRoomReplyTarget? { replyTargets[threadID ?? ""] }
    func beginReply(to event: BotRoomEvent, in threadID: String?) {
        guard event.kind == "message.member", mayReply(in: threadID) else { return }
        let context = threadID ?? ""
        let target = BotRoomReplyTarget(event: event, in: room)
        replyTargets[context] = target
        let current = draft(in: threadID)
        let previous = insertedReplyHandles[context]
        if let handle = target.handle {
            if let previous, previous.caseInsensitiveCompare(handle) == .orderedSame,
               BotRoomReplyTarget.startsWithMention(previous, in: current) {
                return
            }
            let base = previous.map { BotRoomReplyTarget.strippingLeadingMention($0, from: current) } ?? current
            let updated = BotRoomReplyTarget.addressing(base, to: handle)
            setDraft(updated, in: threadID)
            insertedReplyHandles[context] = updated == base ? nil : handle
        } else if let previous {
            setDraft(BotRoomReplyTarget.strippingLeadingMention(previous, from: current), in: threadID)
            insertedReplyHandles[context] = nil
        }
    }
    func cancelReply(in threadID: String?) { replyTargets[threadID ?? ""] = nil }
    func uncertainSend(in threadID: String?) -> Send? { uncertainSends.first { $0.contextThreadID == threadID } }
    private static let unknownOutcomeMessage = String(localized: "Outcome unknown. Reconnect to check the room. Commands are never resent automatically.")
    private static let draftLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "BotRoomDraftStore")
    private(set) var commandMessage: String?
    var uncertainSend: Send? { uncertainSend(in: nil) }
    private(set) var uncertainDisband = false
    private var renaming = false
    private(set) var busy = false
    private(set) var awaitingStop = false
    private(set) var inactiveActions = Set<BotRoomAction.Identity>()
    private(set) var feedback: BotFeedback?
    struct Send: Codable, Equatable {
        let text: String
        let eventID: String
        let attachments: [BotRoomAttachment]
        let threadID: String
        let contextThreadID: String?
        init(text: String, threadID: String? = nil, attachments: [BotRoomAttachment] = []) {
            self.text = text; eventID = UUID().uuidString
            self.attachments = attachments
            self.threadID = threadID ?? UUID().uuidString; contextThreadID = threadID
        }
        var serverEventID: String {
            "user:" + SHA256.hash(data: Data(eventID.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    @ObservationIgnored private var didOpen = false
    @ObservationIgnored private var viewOwner: UUID?
    @ObservationIgnored private var commandID: UUID?
    @ObservationIgnored private var dispatched = false
    @ObservationIgnored private var sending: Send?
    @ObservationIgnored private var stateRevision = 0
    @ObservationIgnored private var log = BotRoomLog()
    @ObservationIgnored private var recentOwner: UUID?
    @ObservationIgnored private var hasRecentLog = false
    @ObservationIgnored private var restoredFromDisk = false
    @ObservationIgnored private var wire: (any BotTransport)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var changeEvents = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var recentBroadcastIDs: [String] = []
    @ObservationIgnored private var capabilities = BotRoomCapabilities(.null)
    @ObservationIgnored private var lastAuthority: BotJSON?
    @ObservationIgnored private let makeWire: @MainActor (BotConnection) -> any BotTransport
    @ObservationIgnored private let onExpired: () -> Void
    @ObservationIgnored private let onChanged: (BotGroupRoom) -> Void
    @ObservationIgnored private let onDisbanded: () -> Void
    @ObservationIgnored private let reconnect: BotReconnectSchedule

    init(key: BotRoomKey, connection: BotConnection, room: BotGroupRoom,
         cache: BotHistoryCache = .shared, drafts: BotRoomDraftStore? = nil, initialSequence: Int? = nil,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onExpired: @escaping () -> Void = {},
         onChanged: @escaping (BotGroupRoom) -> Void = { _ in },
         onDisbanded: @escaping () -> Void = {},
         reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied },
         attachmentNow: @escaping () -> Date = Date.init) {
        self.attachmentNow = attachmentNow
        self.key = key; self.connection = connection; self.room = room
        self.cache = cache; self.initialSequence = initialSequence
        let draftStore = drafts ?? .shared
        let saved = draftStore.load(key)
        self.draftStore = draftStore
        draftGeneration = saved.generation
        self.onChanged = onChanged; self.onDisbanded = onDisbanded
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: key.server) }; self.onExpired = onExpired
        reconnect = BotReconnectSchedule(delays: reconnectDelays, limit: reconnectDelays.count,
                                         isNetworkAvailable: isNetworkAvailable)
        self.drafts = saved.draft.texts
        if let pending = saved.draft.pending {
            uncertainSends = [pending]
            commandMessage = Self.unknownOutcomeMessage
        }
        if let recent = cache.recent.log(for: .init(key)) {
            log = recent; publishLog()
            hasRecentLog = true
        }
    }

    func open(owner: UUID? = nil, preservingLoadedHistory: Bool = false) async {
        viewOwner = owner
        suspend()
        if preservingLoadedHistory && !log.events.isEmpty {
            hasRecentLog = true
        } else if let recent = cache.recent.log(for: .init(key)) {
            log = recent; publishLog()
            hasRecentLog = true
        } else {
            log = BotRoomLog(); events = []; threads = []; hasEarlier = false; hasRecentLog = false
            if !attachmentLists.isEmpty { attachmentLists = [:] }
            if !pauses.isEmpty { pauses = [:] }
            if !pausedThreadIDs.isEmpty { pausedThreadIDs = [] }
            if !handoffs.isEmpty { handoffs = [:] }
            if !memberOutcomes.isEmpty { memberOutcomes = [:] }
        }
        recentOwner = cache.recent.begin(.init(key))
        if needsSignIn {
            await historyRemoval?.value
            let cached = try? await cache.roomHistory(key)
            guard viewOwner == owner, wire == nil, !Task.isCancelled else { return }
            restore(cached); link = .stopped
            return
        }
        let client = makeWire(connection)
        wire = client; link = .connecting; errorMessage = nil
        client.onEvent = { [weak self, weak client] event in
            guard let self, let client, self.wire === client else { return }
            self.roomDidChange(event, from: client)
        }
        client.onDisconnect = { [weak self] error in
            guard let self, self.wire === client else { return }
            self.fail(error, client)
        }
        do {
            await historyRemoval?.value
            let cached = try? await cache.roomHistory(key)
            try check(client)
            restore(cached)
            try await client.connect()
            try check(client)
            let value = try await client.call(.groupsCapabilities)
            try check(client)
            capabilities = BotRoomCapabilities(value)
            guard capabilities.readable else { throw BotFailure.unsupported }
            if uncertainDisband, try await reconcileDisband(client) { return }
            let latest = try await readState(client)
            var initial = log
            let target = didOpen ? nil : initialSequence
            if (!hasRecentLog && cached == nil) || latest < initial.cursor {
                initial.begin(latest: latest)
                if let sequence = target, sequence > 0, sequence <= latest {
                    initial.begin(latest: latest - sequence < 199 ? latest : sequence + 199)
                }
            } else if restoredFromDisk {
                initial.rewind(to: BotRoomLog.windowStart(before: initial.cursor))
            }
            if let sequence = target, sequence > 0, sequence <= initial.earlierBoundary {
                let earlier = try await readPages(client, since: sequence - 1, through: initial.earlierBoundary)
                try check(client)
                for page in earlier { initial.apply(page) }
                initial.loadedEarlier(from: sequence - 1)
            }
            let pages = try await readPages(client, since: initial.cursor)
            try check(client)
            for page in pages { initial.apply(page) }
            log = initial; contextRead = false
            try await readContextIfNeeded(client)
            publishLog()
            if try observeAuthority(pages.last, client) { _ = try await readState(client) }
            try check(client)
            if !changeEvents { refreshPending = false }
            link = .live; didOpen = true; hasRecentLog = true; restoredFromDisk = false
            reconnect.succeeded()
            saveRecentTranscript()
            startPendingRefresh(client)
            pollTask = Task { [weak self] in
                var last = ContinuousClock.now
                while let self, self.wire === client, !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard self.wire === client, !Task.isCancelled else { return }
                    guard ContinuousClock.now - last >= self.pollInterval else { continue }
                    last = .now
                    await self.poll()
                }
            }
        } catch { fail(error, client) }
    }

    @ObservationIgnored private var contextRead = false
    @discardableResult
    private func readContextIfNeeded(_ client: any BotTransport) async throws -> Bool {
        guard context == nil, !contextRead, !log.hasRoutingContext, !status.activity.isEmpty else { return false }
        contextRead = true
        let head = try await client.call(.groupsLog(roomID: key.roomID, sinceSeq: 0, limit: min(capabilities.pageLimit, 20)))
        try check(client)
        log.applySignals(head)
        return true
    }

    var pollInterval: Duration {
        if !changeEvents, let sentAt, ContinuousClock.now - sentAt < .seconds(20) { return .seconds(1) }
        let interval = status.interval
        return changeEvents && interval == .seconds(10) ? .seconds(15) : interval
    }

    private func roomDidChange(_ event: BotJSON, from client: any BotTransport) {
        guard event["type"].text == "groups.changed", changeEvents || link == .connecting else { return }
        let payload = event["payload"]
        if let rooms = payload["room_ids"].list, !rooms.isEmpty, !rooms.contains(.string(key.roomID)) { return }
        if let id = payload["broadcast_id"].text, !id.isEmpty {
            guard !recentBroadcastIDs.contains(id) else { return }
            if recentBroadcastIDs.count == 64 { recentBroadcastIDs.removeFirst() }
            recentBroadcastIDs.append(id)
        }
        requestRefresh(client)
    }

    private func requestRefresh(_ client: any BotTransport) {
        refreshPending = true
        startPendingRefresh(client)
    }

    private func startPendingRefresh(_ client: any BotTransport) {
        guard wire === client, link == .live, refreshPending,
              refreshTask == nil, !loadingEarlier else { return }
        _ = startRefresh(client)
    }

    func poll() async {
        guard let client = wire, link == .live else { return }
        let hasUpload = attachmentDrafts.values.contains { chips in
            chips.contains { chip in
                if case .uploading = chip.state { return true }
                return false
            }
        }
        guard !hasUpload else { return }
        _ = await poll(client)
    }

    private func poll(_ client: any BotTransport) async -> Bool {
        if let refreshTask { _ = await refreshTask.value }
        guard wire === client, link == .live, !Task.isCancelled else { return false }
        return await (refreshTask ?? startRefresh(client)).value
    }

    private func startRefresh(_ client: any BotTransport) -> Task<Bool, Never> {
        let task = Task { [weak self] in
            guard let self, self.wire === client, !Task.isCancelled else { return false }
            if !self.loadingEarlier { self.refreshPending = false }
            let refreshed = await self.readChanges(client)
            if self.wire === client, !Task.isCancelled {
                self.refreshTask = nil
                self.startPendingRefresh(client)
            }
            return refreshed
        }
        refreshTask = task
        return task
    }

    private func readChanges(_ client: any BotTransport) async -> Bool {
        guard wire === client, link == .live else { return false }
        do {
            let revision = stateRevision + 1
            let latest = try await readState(client)
            let readCurrentState = revision == stateRevision
            if try await readContextIfNeeded(client) { publishLog() }
            guard latest > log.cursor else { return readCurrentState }
            let pages = try await readPages(client, since: log.cursor)
            try check(client)
            for page in pages { log.apply(page) }
            publishLog()
            if try observeAuthority(pages.last, client) { _ = try await readState(client) }
            return readCurrentState
        } catch {
            fail(error, client)
            return false
        }
    }

    func loadEarlier() async {
        guard let client = wire, link == .live, hasEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        if let refreshTask { _ = await refreshTask.value }
        guard wire === client else { return }
        let boundary = log.earlierBoundary
        let start = BotRoomLog.windowStart(before: boundary)
        do {
            let pages = try await readPages(client, since: start, through: boundary)
            try check(client)
            for page in pages { log.apply(page) }
            log.loadedEarlier(from: start); publishLog(); loadingEarlier = false
            startPendingRefresh(client)
        } catch { fail(error, client) }
    }

    func leave(owner: UUID, preservingLoadedHistory: Bool = false) {
        guard viewOwner == owner else { return }
        if preservingLoadedHistory { suspend() } else { close() }
        viewOwner = nil
    }

    func networkPathDidChange() { reconnect.networkPathDidChange() }

    func suspend() {
        attachmentPreviews.suspend()
        interruptUploads()
        reconnect.cancel()
        ApprovalSummaries.shared.leave(summaryScope)
        saveRecentTranscript()
        if busy && dispatched { markUncertain(sending) }
        commandID = nil; busy = false; sending = nil; dispatched = false; renaming = false
        let old = wire; wire = nil
        pollTask?.cancel(); pollTask = nil
        refreshTask?.cancel(); refreshTask = nil
        changeEvents = false; refreshPending = false; recentBroadcastIDs.removeAll()
        old?.onDisconnect = nil; old?.onEvent = nil
        old?.close(); loadingEarlier = false; link = .idle
    }

    func close() {
        suspend(); log = BotRoomLog(); events = []; threads = []; hasEarlier = false
        if context != nil { context = nil }
        if !attachmentLists.isEmpty { attachmentLists = [:] }
        if !pauses.isEmpty { pauses = [:] }
        if !pausedThreadIDs.isEmpty { pausedThreadIDs = [] }
        if !handoffs.isEmpty { handoffs = [:] }
        if !memberOutcomes.isEmpty { memberOutcomes = [:] }
        hasRecentLog = false; restoredFromDisk = false
        status = BotRoomStatus(.null); lastAuthority = nil; runtimeDown = false
    }

    var canParticipate: Bool {
        link == .live && !runtimeDown && !uncertainDisband && !foreignAuthority
            && capabilities.authority != nil && room.authority == capabilities.authority
    }
    var showsComposer: Bool { !foreignAuthority }
    var showsWelcome: Bool { link == .live && !hasEarlier && !BotRoomEvent.hasConversation(in: events) }
    var stopControl: BotRoomStopControl? {
        if finishingStop { return .stopping }
        if status.working { return .stop(enabled: mayStop) }
        return nil
    }
    var mayStop: Bool { allows("groups.stop") && !busy && !awaitingStop && status.stopping == 0 && status.stoppable > 0 }
    var mayContinue: Bool { allows("groups.continue") && !busy && status.maxContinues != nil }
    var mayStopPaused: Bool { allows("groups.stop") && !busy && !awaitingStop && status.stopping == 0 }
    var pausedStopNeedsConfirmation: Bool { status.stoppable > 0 }
    var maySend: Bool { maySend(in: nil) }
    func primaryAction(in threadID: String?) -> BotRoomPrimaryAction {
        if uncertainSend(in: threadID) != nil {
            return .retry(enabled: mayResend(in: threadID))
        }
        return .send(enabled: maySend(in: threadID))
    }
    func mayEditDraft(in threadID: String?) -> Bool { !runtimeDown && !busy && uncertainSend(in: threadID) == nil }
    func mayReply(in threadID: String?) -> Bool { mayEditDraft(in: threadID) && !dictatingThreads.contains(threadID ?? "") }
    func maySend(in threadID: String?) -> Bool {
        guard allows("groups.send"), mayEditDraft(in: threadID), let attachments = uploadedAttachments(in: threadID)
        else { return false }
        return BotRoomRPC.validText(draft(in: threadID), attachments: attachments.count)
            && (threadID == nil || threads.contains { $0.id == threadID })
    }
    func mayResend(in threadID: String?) -> Bool {
        allows("groups.send") && !busy && uncertainSend(in: threadID) != nil
    }
    private func allows(_ method: String) -> Bool { canParticipate && capabilities.methods.contains(method) }
    var mayDownload: Bool { allows(BotRoomAttachment.downloadMethod) }

    var showsAttachmentPicker: Bool { allows(BotRoomFiles.uploadMethod) }

    func mayAddAttachments(in threadID: String?) -> Bool {
        showsAttachmentPicker && mayEditDraft(in: threadID)
    }

    func attachmentChips(in threadID: String?) -> [BotRoomAttachmentChip] {
        attachmentDrafts[threadID ?? ""] ?? []
    }

    func attachmentNotice(in threadID: String?) -> String? { attachmentNotices[threadID ?? ""] }
    func setAttachmentNotice(_ message: String?, in threadID: String?) { attachmentNotices[threadID ?? ""] = message }

    func expireAttachments(in threadID: String?) {
        let context = threadID ?? "", now = attachmentNow()
        guard var chips = attachmentDrafts[context] else { return }
        var changed = false
        for index in chips.indices {
            if case .uploaded(_, let expiry) = chips[index].state, expiry <= now {
                chips[index].state = .expired
                changed = true
            }
        }
        if changed { attachmentDrafts[context] = chips }
    }

    func removeAttachment(_ id: UUID, in threadID: String?) {
        guard mayEditDraft(in: threadID) else { return }
        attachmentDrafts[threadID ?? ""]?.removeAll { $0.id == id }
        setAttachmentNotice(nil, in: threadID)
    }

    func addAttachments(_ inputs: [BotRoomFiles.Input], in threadID: String?) async {
        guard !inputs.isEmpty, mayAddAttachments(in: threadID), let client = wire else { return }
        setAttachmentNotice(nil, in: threadID)
        let context = threadID ?? "", epoch = room.epoch
        let capacity = BotRoomFiles.maximumCount - attachmentChips(in: threadID).count
        if inputs.count > capacity { setAttachmentNotice(BotRoomFiles.Failure.count.localizedDescription, in: threadID) }
        let additions = inputs.prefix(capacity).map { BotRoomAttachmentChip(id: UUID(), name: $0.name, state: .preparing) }
        guard !additions.isEmpty else { return }
        attachmentDrafts[context, default: []].append(contentsOf: additions)
        for (input, chip) in zip(inputs, additions) {
            guard attachmentIndex(chip.id, context: context) != nil else { continue }
            do {
                let media = try await input.load()
                let file = try await Task.detached(priority: .userInitiated) { try BotRoomFiles.prepare(media) }.value
                guard let index = attachmentIndex(chip.id, context: context) else { continue }
                let total = attachmentChips(in: threadID).reduce(0) { $0 + $1.state.byteCount }
                guard total + file.data.count <= BotRoomFiles.maximumMessageBytes else { throw BotRoomFiles.Failure.totalSize }
                attachmentDrafts[context]?[index].name = file.name
                if wire === client, room.epoch == epoch {
                    await upload(file, id: chip.id, context: context, client: client, epoch: epoch)
                } else {
                    attachmentDrafts[context]?[index].state = .failed(file, BotFailure.transport.localizedDescription)
                }
            } catch {
                guard let index = attachmentIndex(chip.id, context: context) else { continue }
                attachmentDrafts[context]?.remove(at: index)
                setAttachmentNotice(error.localizedDescription, in: threadID)
            }
        }
    }

    func retryAttachment(_ id: UUID, in threadID: String?) async {
        let context = threadID ?? ""
        guard mayAddAttachments(in: threadID), let client = wire,
              let chip = attachmentDrafts[context]?.first(where: { $0.id == id }),
              case .failed(let file, _) = chip.state else { return }
        await upload(file, id: id, context: context, client: client, epoch: room.epoch)
    }

    private func uploadedAttachments(in threadID: String?) -> [BotRoomAttachment]? {
        let now = attachmentNow()
        var manifest: [BotRoomAttachment] = []
        for chip in attachmentChips(in: threadID) {
            guard case .uploaded(let item, let expiry) = chip.state, now < expiry else { return nil }
            manifest.append(item)
        }
        return manifest
    }

    private func attachmentIndex(_ id: UUID, context: String) -> Int? {
        attachmentDrafts[context]?.firstIndex { $0.id == id }
    }

    private func uploadIndex(_ id: UUID, context: String, client: any BotTransport, epoch: Int?) -> Int? {
        guard wire === client, room.epoch == epoch else { return nil }
        return attachmentIndex(id, context: context)
    }

    private func upload(_ file: BotRoomUpload, id: UUID, context: String, client: any BotTransport, epoch: Int?) async {
        guard let index = uploadIndex(id, context: context, client: client, epoch: epoch) else { return }
        attachmentDrafts[context]?[index].state = .uploading(file)
        let call = HermesCall.groupsAttachmentUpload(roomID: key.roomID, uploadID: id.uuidString, file: file)
        let state: BotRoomAttachmentChip.State
        do {
            let result = try await client.call(call, validateDispatch: {
                try self.check(client)
                guard self.showsAttachmentPicker, self.uploadIndex(id, context: context, client: client, epoch: epoch) != nil
                else { throw BotFailure.stale }
            })
            guard let item = BotRoomAttachment(result), let attachmentID = item.attachmentID,
                  BotRoomRPC.validID(attachmentID), item.kind == file.kind, item.name == file.name,
                  item.mime == file.mime, item.size == file.data.count else { throw BotFailure.unsupported }
            state = .uploaded(item, expiresAt: attachmentNow().addingTimeInterval(BotRoomFiles.draftLifetime))
        } catch {
            state = .failed(file, error.localizedDescription)
        }
        guard let updated = uploadIndex(id, context: context, client: client, epoch: epoch) else { return }
        attachmentDrafts[context]?[updated].state = state
    }

    private func interruptUploads() {
        for context in Array(attachmentDrafts.keys) {
            guard let chips = attachmentDrafts[context] else { continue }
            let interrupted = chips.map { chip in
                guard case .uploading(let file) = chip.state else { return chip }
                var updated = chip
                updated.state = .failed(file, BotFailure.transport.localizedDescription)
                return updated
            }
            if interrupted != chips { attachmentDrafts[context] = interrupted }
        }
    }

    func downloadAttachment(_ request: BotRoomAttachment.Request) async throws -> Data {
        guard let client = wire, mayDownload else { throw BotFailure.stale }
        let key = BotRoomPreviewQueue.Key(wire: ObjectIdentifier(client), request: request)
        return try await attachmentPreviews.download(key, load: attachmentLoad(request, client: client))
    }

    func previewAttachment(_ request: BotRoomAttachment.Request, namespace: String, observer: UUID,
                           deliver: @escaping BotRoomPreviewQueue.Deliver) {
        guard let client = wire, mayDownload else { return }
        let key = BotRoomPreviewQueue.Key(wire: ObjectIdentifier(client), request: request)
        attachmentPreviews.enqueue(key: key, cacheKey: "\(namespace)|\(connection.id)|attachment:\(request.eventID)|\(request.attachmentID)",
                                   observer: observer, load: attachmentLoad(request, client: client), deliver: deliver)
    }

    func cancelAttachmentPreview(observer: UUID) {
        attachmentPreviews.cancel(observer: observer)
    }

    private func attachmentLoad(_ request: BotRoomAttachment.Request, client: any BotTransport) -> BotRoomPreviewQueue.Load {
        let epoch = room.epoch
        return { [weak self] in
            guard let self else { throw BotFailure.stale }
            let call = HermesCall.groupsAttachmentDownload(roomID: self.key.roomID, eventID: request.eventID,
                                                           attachmentID: request.attachmentID)
            let result = try await client.call(call, validateDispatch: {
                try self.check(client)
                guard self.mayDownload, self.room.epoch == epoch else { throw BotFailure.stale }
            })
            try self.check(client)
            guard result["attachment_id"].text == request.attachmentID,
                  let encoded = result["data_base64"].text,
                  let data = await Task.detached(operation: { Data(base64Encoded: encoded) }).value else {
                throw BotArtifactFailure.unavailable
            }
            try self.check(client)
            guard self.room.epoch == epoch else { throw BotFailure.stale }
            return data
        }
    }

    func mayAct(_ action: BotRoomAction) -> Bool { !busy && isPendingAndAnswerable(action) }

    private func isPendingAndAnswerable(_ action: BotRoomAction) -> Bool {
        action.isAnswerable && !inactiveActions.contains(action.id) && status.actions.contains(action)
            && allows(action.method)
    }

    var showsRename: Bool { !foreignAuthority && capabilities.methods.contains("groups.rename") }
    var showsSettings: Bool { !foreignAuthority && capabilities.methods.contains("groups.context") && context != nil }
    var showsDisband: Bool { !foreignAuthority && capabilities.methods.contains("groups.disband") }
    var mayRename: Bool { allows("groups.rename") && !busy }
    var maySaveContext: Bool { context != nil && allows("groups.context") && !busy }
    var finishingStop: Bool { status.stopping > 0 || awaitingStop }
    var mayDisband: Bool { allows("groups.disband") && !busy && !finishingStop }

    func rename(_ name: String) async {
        guard mayRename, BotRoomRPC.validName(name), name != room.name else { return }
        renaming = true
        await command(.groupsRename(roomID: key.roomID, eventID: UUID().uuidString, name: name), validate: {}, accept: { result in
            guard let updated = BotGroupRoom(result["room"]), updated.id == self.key.roomID,
                  !updated.disbanded else { throw BotFailure.unsupported }
            self.stateRevision += 1
            self.room = updated; self.onChanged(updated)
        })
    }

    func saveContext(_ draft: HermesCall.RoomContext) async -> Bool {
        guard maySaveContext else { return false }
        var saved = false
        await command(.groupsContext(roomID: key.roomID, eventID: UUID().uuidString, draft), validate: {
            if draft.routing == "lead", !self.room.members.contains(where: { $0.id == draft.leadMemberID }) {
                throw BotFailure.stale
            }
        }, accept: { result in
            guard let updated = BotRoomContext(result["context"]) else { throw BotFailure.unsupported }
            self.stateRevision += 1
            if self.context != updated { self.context = updated }
            saved = true
        })
        return saved
    }

    func disband() async {
        guard mayDisband else { return }
        let owner = viewOwner
        await command(.groupsDisband(roomID: key.roomID), validate: {
            guard !self.finishingStop else { throw BotFailure.stale }
            self.uncertainDisband = true
        }, accept: { result in
            guard result["tombstone"]["room_id"].text == self.key.roomID,
                  result["tombstone"]["disbanded_at"].number != nil else { throw BotFailure.unsupported }
            self.finishDisband()
        })
        if viewOwner == owner && uncertainDisband && link == .stopped { await open(owner: owner) }
    }

    private func finishDisband() {
        uncertainDisband = false; discardHistory(); close(); onDisbanded()
    }

    private func reconcileDisband(_ client: any BotTransport) async throws -> Bool {
        let rooms = try await BotRoomList.read(client) { try self.check(client) }
        if !rooms.contains(where: { $0.id == key.roomID }) { finishDisband(); return true }
        uncertainDisband = false
        commandMessage = String(localized: "The room is still present. Disband was not confirmed.")
        return false
    }

    func send(retry: Bool = false, threadID: String? = nil) async {
        let request: Send
        if retry {
            guard mayResend(in: threadID), let pending = uncertainSend(in: threadID) else { return }
            request = pending
        } else {
            guard maySend(in: threadID), let attachments = uploadedAttachments(in: threadID) else { return }
            request = Send(text: draft(in: threadID), threadID: threadID, attachments: attachments)
        }
        let context = threadID ?? ""
        sending = request
        let send = HermesCall.groupsSend(roomID: key.roomID, eventID: request.eventID, text: request.text,
                                         threadID: request.threadID, attachments: request.attachments)
        await command(send, validate: {
            if !retry && self.uploadedAttachments(in: threadID) != request.attachments { throw BotFailure.stale }
            try self.writeDrafts(pending: self.uncertainSends.first ?? request)
        }, accept: { result in
            let value = result["event"]
            guard result["accepted"].flag == true, result["client_event_id"].text == request.eventID,
                  value["room_id"].text == self.key.roomID, let event = BotRoomEvent(value),
                  event.kind == "message.user", event.threadID == request.threadID,
                  event.payload["text"].text != nil || !event.roomAttachments.isEmpty,
                  request.attachments == event.roomAttachments else { throw BotFailure.unsupported }
            self.log.acknowledge(value)
            self.sending = nil
            self.clearDeliveredSend(request)
            self.persistDrafts()
            self.publishLog()
            self.feedback = BotFeedback(.sent, after: self.feedback)
            self.sentAt = .now
        }, reconcileSendRetry: retry ? {
            self.sending = nil
            _ = self.settleLandedSends()
            if self.uncertainSend(in: threadID) == nil {
                self.commandMessage = nil
            } else {
                self.uncertainSends.removeAll { $0.eventID == request.eventID }
                if !request.attachments.isEmpty {
                    self.attachmentDrafts[context] = nil; self.attachmentNotices[context] = nil
                    self.commandMessage = String(localized: "Attachments expired. Add them again before sending.")
                }
                self.drafts[context] = request.text.isEmpty ? nil : request.text
                self.persistDrafts()
            }
            self.publishLog()
        } : nil)
    }

    func stop() async {
        guard mayStop else { return }
        await command(.groupsStop(roomID: key.roomID, cancelID: UUID().uuidString),
                      validate: { guard self.status.stoppable > 0 else { throw BotFailure.stale } }, accept: { result in
            guard result["cancelled"].integer != nil else { throw BotFailure.unsupported }
            self.awaitingStop = true
            self.feedback = BotFeedback(.stopped, after: self.feedback)
        })
    }

    func continueDiscussion(_ id: String) async {
        guard mayContinue else { return }
        await command(.groupsContinue(roomID: key.roomID, discussionEventID: id), validate: {}, accept: { result in
            let value = result["event"]
            guard result["continued"].flag == true, BotRoomEvent(value)?.kind == "room.continued" else {
                throw BotFailure.unsupported
            }
            self.log.acknowledge(value)
            self.publishLog()
        })
    }

    func stopPausedDiscussion() async {
        guard mayStopPaused else { return }
        await command(.groupsStop(roomID: key.roomID, cancelID: UUID().uuidString), validate: {}, accept: { result in
            guard result["cancelled"].integer != nil else { throw BotFailure.unsupported }
            self.awaitingStop = true
            self.feedback = BotFeedback(.stopped, after: self.feedback)
        })
    }

    private var summaryScope: ApprovalSummaries.Scope {
        .init(server: key.server, connectionID: connection.id, conversation: .room(id: key.roomID, epoch: room.epoch))
    }

    func summaryPresentation(for action: BotRoomAction) -> ApprovalSummaryPresentation? {
        guard isPendingAndAnswerable(action), let client = wire, let approval = action.approval,
              let profile = room.members.first(where: { $0.id == action.id.member })?.profile, !profile.isEmpty,
              let input = ApprovalSummaries.input(description: approval.consequence, command: approval.command,
                                                  cwd: approval.workingDirectory) else { return nil }
        let key = ApprovalSummaries.Key(scope: summaryScope, request: .room(action.id))
        return ApprovalSummaryPresentation(key: key) { [weak self] in
            guard let self else { throw BotFailure.stale }
            let reply = try await client.call(.approvalSummary(input: input, language: ApprovalSummaries.language(), sessionID: nil, profile: profile), validateDispatch: {
                guard self.wire === client, self.summaryScope == key.scope, self.isPendingAndAnswerable(action) else { throw BotFailure.stale }
            })
            guard let text = reply["text"].text else { throw BotFailure.unsupported }
            return text
        }
    }

    func act(_ action: BotRoomAction, choice: BotApprovalRequest.Choice? = nil) async {
        guard mayAct(action), let call = action.call(roomID: key.roomID, choice: choice) else { return }
        let summaryKey = ApprovalSummaries.Key(scope: summaryScope, request: .room(action.id))
        await command(call, validate: {
            guard self.status.actions.contains(action), !self.inactiveActions.contains(action.id) else { throw BotFailure.stale }
            self.inactiveActions.insert(action.id)
        }, accept: { result in
            let acknowledged = action.isRetry ? "retried" : action.isDiscard ? "discarded" : "approved"
            guard result[acknowledged].flag == true else { throw BotFailure.unsupported }
            if action.approval != nil, let choice {
                ApprovalSummaries.shared.remove(summaryKey)
                self.feedback = BotFeedback(.approved(choice), after: self.feedback)
            }
        })
    }

    private func command(_ call: HermesCall, validate: @escaping () throws -> Void,
                         accept: (BotJSON) throws -> Void, reconcileSendRetry: (() -> Void)? = nil) async {
        guard let client = wire, allows(call.method), !busy else { sending = nil; return }
        let token = UUID(), epoch = room.epoch
        commandID = token; busy = true; dispatched = false; commandMessage = nil
        var reconciled = false
        do {
            let result = try await client.call(call, validateDispatch: { [weak self] in
                guard let self, self.commandID == token, self.wire === client, self.allows(call.method),
                      self.room.epoch == epoch, !Task.isCancelled else { throw BotFailure.stale }
                try validate()
                self.dispatched = true
                self.stateRevision += 1
            })
            guard commandID == token, wire === client else { return }
            try check(client)
            try accept(result)
        } catch {
            guard commandID == token, wire === client else { return }
            if let rejection = error as? BotRoomFailure {
                if case .groupsDisband = call { uncertainDisband = false }
                if case .groupsContinue = call, !rejection.expired {
                    commandMessage = String(localized: "Couldn’t continue the discussion.")
                } else {
                    commandMessage = rejection.localizedDescription
                }
                if rejection.reason == "authority_conflict" { foreignAuthority = true }
                if rejection.expired { discardHistory(); close(); onExpired(); return }
                if let sending, uncertainSend(in: sending.contextThreadID) == nil {
                    self.sending = nil
                    persistDrafts()
                }
                if rejection.rejectsSendBeforeAdmission, let reconcileSendRetry {
                    let refreshed = await poll(client)
                    guard commandID == token, wire === client else { return }
                    if refreshed && room.epoch == epoch && allows(call.method) { reconcileSendRetry() }
                    reconciled = true
                }
            } else if dispatched {
                markUncertain(sending)
            } else { commandMessage = error.localizedDescription }
        }
        guard commandID == token, wire === client else { return }
        commandID = nil; busy = false; dispatched = false; sending = nil; renaming = false
        if uncertainDisband {
            do { if try await reconcileDisband(client) { return } }
            catch { fail(error, client); return }
        }
        if !reconciled { requestRefresh(client) }
    }

    private func check(_ client: any BotTransport) throws {
        guard wire === client, !Task.isCancelled else { throw BotFailure.stale }
    }

    private func readState(_ client: any BotTransport) async throws -> Int {
        stateRevision += 1
        let revision = stateRevision
        let value = try await client.call(.groupsState(roomID: key.roomID))
        try check(client)
        guard let updated = BotGroupRoom(value["room"]), updated.id == key.roomID else { throw BotFailure.unsupported }
        guard revision == stateRevision else { return room.latestSeq }
        if updated.disbanded { throw BotRoomFailure(code: 4114, reason: nil) }
        changeEvents = value["change_events"].flag == true
        let previousSummaryScope = summaryScope
        var membersChanged = false
        if !renaming && room != updated {
            membersChanged = room.members != updated.members
            room = updated; onChanged(updated)
        }
        if previousSummaryScope != summaryScope {
            interruptUploads()
            ApprovalSummaries.shared.retain([], in: previousSummaryScope)
        }
        let driverStatus = value["driver_status"]
        let nextRuntimeDown = driverStatus == .null
        if runtimeDown != nextRuntimeDown { runtimeDown = nextRuntimeDown }
        let nextStatus = BotRoomStatus(driverStatus)
        let nextContext = BotRoomContext(value["context"])
        if context != nextContext { context = nextContext }
        let pendingSummaries = nextStatus.actions.filter { $0.approval != nil }.map {
            ApprovalSummaries.Key(scope: summaryScope, request: .room($0.id))
        }
        ApprovalSummaries.shared.retain(Set(pendingSummaries), in: summaryScope)
        var shouldRepublish = membersChanged
        if status != nextStatus {
            if status.maxContinues != nextStatus.maxContinues { shouldRepublish = true }
            status = nextStatus
        }
        if shouldRepublish && link == .live && updated.latestSeq <= log.cursor { publishLog() }
        if !busy && nextStatus.stopping == 0 { awaitingStop = false }
        let pendingIDs = Set(nextStatus.actions.map(\.id))
        inactiveActions = inactiveActions.filter { !["retry", "discard"].contains($0.kind) || pendingIDs.contains($0) }
        let foreign = updated.isForeign(to: capabilities.authority)
        if foreignAuthority != foreign { foreignAuthority = foreign }
        return updated.latestSeq
    }

    private func readPages(_ client: any BotTransport, since: Int, through: Int? = nil) async throws -> [BotJSON] {
        var cursor = since
        var pages: [BotJSON] = []
        let receivedAt = Date()
        while true {
            let limit = min(capabilities.pageLimit, through.map { max(1, $0 - cursor) } ?? capabilities.pageLimit)
            let page = try await client.call(.groupsLog(roomID: key.roomID, sinceSeq: cursor, limit: limit))
            try check(client)
            guard page["events"].list != nil, let next = page["cursor"].integer, next >= cursor,
                  let more = page["has_more"].flag else { throw BotFailure.unsupported }
            pages.append(page)
            if !more || through.map({ next >= $0 }) == true { break }
            guard next > cursor else { throw BotFailure.unsupported }
            cursor = next
        }
        let projection = BotJSON.object([
            "events": .array(pages.flatMap { $0["events"].list ?? [] }),
            "cursor": pages.last?["cursor"] ?? .number(Double(since))
        ])
        try? await cache.appendRoom(key: key, room: room, page: projection, since: since, receivedAt: receivedAt)
        try check(client)
        return pages
    }

    private func observeAuthority(_ page: BotJSON?, _ client: any BotTransport) throws -> Bool {
        try check(client)
        guard let authority = page?["authority"], authority != .null else { return false }
        let moved = lastAuthority != nil && lastAuthority != authority
        lastAuthority = authority
        if let owner = authority["gateway_id"].text, let local = capabilities.authority, owner != local {
            foreignAuthority = true
        }
        return moved
    }

    private func restore(_ cached: BotHistoryCache.Snapshot?) {
        guard let cached, !hasRecentLog else { return }
        var restored = BotRoomLog()
        restored.apply(cached.replayPage)
        restored.loadedEarlier(from: cached.earlierBoundary ?? 0)
        restoredFromDisk = true
        log = restored; publishLog()
    }

    private func markUncertain(_ send: Send?) {
        commandMessage = Self.unknownOutcomeMessage
        guard let send else { return }
        sending = nil
        if uncertainSend(in: send.contextThreadID) == nil { uncertainSends.append(send) }
        if settleLandedSends() { publishLog() } else { persistDrafts() }
    }

    private func settleLandedSends() -> Bool {
        var settled = false
        for send in uncertainSends {
            guard send.eventID != sending?.eventID else { continue }
            let eventID = send.serverEventID
            guard log.events.contains(where: { $0.kind == "message.user" && $0.eventID == eventID }) else { continue }
            clearDeliveredSend(send)
            settled = true
        }
        if settled {
            if uncertainSends.isEmpty && commandMessage == Self.unknownOutcomeMessage { commandMessage = nil }
            persistDrafts()
        }
        return settled
    }

    private func clearDeliveredSend(_ send: Send) {
        let context = send.contextThreadID ?? ""
        uncertainSends.removeAll { $0.eventID == send.eventID }
        attachmentDrafts[context] = nil; attachmentNotices[context] = nil
        replyTargets[context] = nil; insertedReplyHandles[context] = nil
        if draft(in: send.contextThreadID) == send.text { drafts[context] = nil }
    }

    private func writeDrafts(pending: Send?) throws {
        try draftStore.save(.init(texts: drafts, pending: pending), for: key, generation: draftGeneration)
    }

    private func persistDrafts() {
        do { try writeDrafts(pending: uncertainSends.first ?? (dispatched ? sending : nil)) }
        catch BotFailure.stale {}
        catch { Self.draftLogger.error("Could not save room drafts: \(error.localizedDescription, privacy: .private)") }
    }

    private func publishLog() {
        _ = settleLandedSends()
        let pendingIDs = Set((uncertainSends + [sending].compactMap { $0 }).map(\.serverEventID))
        let unpending = log.events.filter { event in
            event.kind != "message.user" || !pendingIDs.contains(event.eventID ?? "")
        }
        let visible = unpending.filter { !$0.isRoutingEvent || $0.routingText(in: room) != nil }
        if events != visible {
            events = visible
            var lists: [Int: BotRoomAttachmentList] = [:]
            for event in visible { lists[event.seq] = BotRoomAttachmentList(event) }
            if attachmentLists != lists { attachmentLists = lists }
        }
        let round = (unpending + log.signals).sorted { $0.seq < $1.seq }
        if roundEvents != round { roundEvents = round }
        let nextOutcomes = BotRoomMemberOutcome.latest(in: round)
        if memberOutcomes != nextOutcomes { memberOutcomes = nextOutcomes }
        let nextHandoffs = BotRoomHandoffs.find(in: round, members: room.members)
        if handoffs != nextHandoffs { handoffs = nextHandoffs }
        let nextPauses: [Int: BotRoomPause]
        if capabilities.methods.contains("groups.continue"), let limit = status.maxContinues {
            nextPauses = BotRoomPause.pauses(in: log.events, maxContinues: limit)
        } else {
            nextPauses = [:]
        }
        if pauses != nextPauses { pauses = nextPauses }
        let pausedThreads = Set(log.events.lazy.filter { nextPauses[$0.seq]?.actionable == true }.compactMap(\.threadID))
        if pausedThreadIDs != pausedThreads { pausedThreadIDs = pausedThreads }
        hasEarlier = log.earlierBoundary > 0
        let grouped = BotRoomThread.group(visible, hasEarlier: hasEarlier)
        if threads != grouped { threads = grouped }
    }

    private func saveRecentTranscript() {
        guard link == .live, !busy, !uncertainDisband, let recentOwner else { return }
        cache.recent.save(log.recentWindow(), for: .init(key), owner: recentOwner)
    }

    private func discardHistory() {
        let cache = cache, key = key
        draftStore.removeRoom(key)
        drafts = [:]; uncertainSends = []; sending = nil
        cache.recent.remove { $0 == .init(key) }
        recentOwner = nil
        historyRemoval = Task { try? await cache.removeRoom(key) }
    }

    private func fail(_ error: Error, _ client: any BotTransport) {
        guard wire === client else { return }
        suspend(); link = .stopped
        errorMessage = error.localizedDescription
        needsSignIn = error as? BotFailure == .rejected(401)
        if let failure = error as? BotRoomFailure, failure.expired { discardHistory(); close(); onExpired() }
        let heals = switch error as? BotFailure {
        case .transport: true
        case .rejected: BotConnectionAdvice.isRetryable(error)
        default: error is URLError
        }
        guard let owner = viewOwner, heals else { return }
        reconnect.schedule { [weak self] in
            guard let self, self.viewOwner == owner, self.link == .stopped else { return }
            await self.open(owner: owner, preservingLoadedHistory: true)
        }
    }
}
