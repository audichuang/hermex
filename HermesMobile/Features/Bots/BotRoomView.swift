import SwiftUI

@MainActor struct BotRoomView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var reader: BotRoomReader
    @State private var revision = UUID()
    @State private var showingProfile = false
    @State private var selectedThread: String?
    @State private var threadSequence: Int?
    let threadID: String?
    @State private var visible = false
    @State private var owner = UUID()
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var isNearBottom = true
    @State private var pendingSequence: Int?
    @State private var showRequestID = UUID()
    @State private var composerFocusRequest: UUID?
    @State private var dismissedErrors: Set<String> = []
    @State private var window = BotRoomTranscriptWindow()
    private var followsLatest: Bool { followLatch.isFollowing }
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let hostProfile: String?
    let onUpdateSignIn: () -> Void

    init(reader: BotRoomReader, roster: [BotProfile], avatars: [String: UIImage], hostProfile: String? = nil, threadID: String? = nil, sequence: Int? = nil, onUpdateSignIn: @escaping () -> Void = {}) {
        _reader = State(initialValue: reader); self.roster = roster; self.avatars = avatars
        self.hostProfile = hostProfile
        self.onUpdateSignIn = onUpdateSignIn; self.threadID = threadID
        _pendingSequence = State(initialValue: sequence ?? (threadID == nil ? reader.initialSequence : nil))
    }

    var body: some View {
        ScrollViewReader { proxy in
            let start = window.start(in: transcriptEvents, keeping: pendingSequence, overview: showsThreadOverview)
            let hasHiddenEvents = start > 0
            let showsWelcome = threadID == nil && reader.showsWelcome
            ScrollView {
                ZStack {
                    if showsWelcome { Color.clear.containerRelativeFrame(.vertical) }
                    if transcriptEvents.isEmpty && reader.link == .connecting {
                        ProgressView()
                            .containerRelativeFrame(.vertical)
                            .accessibilityLabel(Text("Loading…"))
                    }
                    VStack(spacing: 16) {
                        if !showsThreadOverview && (hasHiddenEvents || reader.hasEarlier) {
                            Button("Load earlier") { loadEarlier(proxy: proxy) }
                                .disabled(!hasHiddenEvents && (reader.loadingEarlier || reader.link != .live))
                        }
                        if reader.foreignAuthority {
                            Text("Managed by another Hermes").font(AppFont.caption()).foregroundStyle(.appSecondary)
                        }
                        if threadID != nil, reader.threads.first(where: { $0.id == threadID })?.root == nil {
                            Text("Earlier messages not loaded").font(AppFont.caption()).foregroundStyle(.appSecondary)
                        }
                        let rows = Array(transcriptEvents[start...])
                        let mayReply = reader.mayReply(in: threadID)
                        ForEach((showsThreadOverview ? Array(rows.reversed()) : rows).map {
                            BotRoomTranscriptRow(event: $0, isOverview: threadID == nil)
                        }) { row in
                            let event = row.event
                            if threadID == nil, let thread = reader.threads.first(where: { $0.latest.seq == event.seq }) {
                                Button { selectedThread = thread.id } label: {
                                    BotRoomThreadPreview(thread: thread, reader: reader,
                                                         rootFiles: thread.root.flatMap { reader.attachmentLists[$0.seq]?.summary },
                                                         isPaused: reader.pausedThreadIDs.contains(thread.id))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("room-thread-\(thread.id)")
                            } else if event.isBoundedActivity {
                                BotRoomPausedRow(event: event, reader: reader)
                            } else {
                                BotRoomEventView(
                                    event: event,
                                    files: reader.attachmentLists[event.seq]?.files ?? [],
                                    handoffs: reader.handoffs[event.seq] ?? [],
                                    reader: reader,
                                    roster: roster,
                                    avatars: avatars,
                                    transcriptMediaCacheNamespace: "\(reader.key.server.absoluteString)|bot-room:\(reader.room.id)",
                                    mayReply: mayReply,
                                    onReply: threadID != nil && event.kind == "message.member" && event.threadID != nil && reader.showsComposer ? {
                                        guard reader.mayReply(in: threadID) else { return }
                                        reader.beginReply(to: event, in: threadID)
                                        composerFocusRequest = UUID()
                                    } : nil
                                )
                            }
                        }
                        if showsThreadOverview && (hasHiddenEvents || reader.hasEarlier) {
                            Button("Load earlier") { loadEarlier(proxy: proxy) }
                                .disabled(!hasHiddenEvents && (reader.loadingEarlier || reader.link != .live))
                        }
                        if showsWelcome {
                            BotRoomWelcomeView(room: reader.room, roster: roster, avatars: avatars,
                                               showsPrompt: reader.showsComposer && !reader.runtimeDown)
                        }
                        Color.clear.frame(height: 0).id("room-actions")
                        ForEach(Array(reader.status.actions.enumerated()), id: \.offset) { _, action in
                            BotRoomActionCard(reader: reader, action: action)
                        }
                        Color.clear.frame(height: 1).id("room-bottom")
                    }
                    .padding(16)
                    .frame(maxWidth: ChatReadingWidth.maximumWidth(horizontalPadding: 16))
                    .frame(maxWidth: .infinity)
                    .background {
                        ChatScrollObserver(isStreaming: false, onFollowEvent: handleFollowEvent, onMetrics: updateScrollMetrics)
                            .accessibilityHidden(true)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .defaultScrollAnchor(showsThreadOverview ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(showsThreadOverview ? nil : ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: followsLatest), for: .sizeChanges)
            .onChange(of: availableSearchSequence, initial: true) { _, sequence in
                guard threadID == nil, let sequence else { return }
                if let target = reader.events.first(where: { $0.seq == sequence })?.threadID {
                    threadSequence = sequence; selectedThread = target; pendingSequence = nil
                    return
                }
                handleFollowEvent(.userScrollBegin)
                window.reveal(sequence, in: transcriptEvents, overview: showsThreadOverview)
                proxy.scrollTo(BotRoomTranscriptRow.ID.event(sequence), anchor: .center); pendingSequence = nil
            }
            .task(id: threadID == nil ? nil : availableSearchSequence) {
                guard threadID != nil, let sequence = availableSearchSequence else { return }
                window.reveal(sequence, in: transcriptEvents, overview: showsThreadOverview)
                await Task.yield()
                guard !Task.isCancelled else { return }
                handleFollowEvent(.userScrollBegin)
                proxy.scrollTo(BotRoomTranscriptRow.ID.event(sequence), anchor: .center); pendingSequence = nil
            }
            .onChange(of: transcriptEvents.last?.seq, initial: true) { seedWindow() }
            .onChange(of: reader.link) { seedWindow() }
            .onChange(of: transcriptEvents.last?.seq) {
                if !showsThreadOverview && pendingSequence == nil && followsLatest { proxy.scrollTo("room-bottom", anchor: .bottom) }
            }
            .onChange(of: showRequestID) { proxy.scrollTo("room-actions", anchor: .top) }
            .overlay(alignment: .bottom) {
                if !showsThreadOverview && !isNearBottom && !transcriptEvents.isEmpty {
                    ChatScrollToBottomButton(bottomPadding: 12) {
                        handleFollowEvent(.reset); proxy.scrollTo("room-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let pill {
                    BotComposerPillView(pill: pill, onReconnect: { revision = UUID() }, onUpdateSignIn: onUpdateSignIn,
                        onShowRequest: { showRequestID = UUID() },
                        onDismissError: { if let text = pill.errorText { dismissedErrors.insert(text) } },
                        onRetrySend: { Task { await reader.send(retry: true, threadID: threadID) } })
                }
                if let round = BotRoomRound.build(events: reader.roundEvents, activity: reader.status.activity,
                                                  room: reader.room, threadID: threadID, context: reader.context,
                                                  maxRounds: reader.status.maxRounds) {
                    BotRoomActivityStrip(round: round)
                }
                if reader.showsComposer {
                    BotRoomComposerView(reader: reader, threadID: threadID, focusRequest: composerFocusRequest,
                                        roster: roster, avatars: avatars)
                }
            }
            .frame(maxWidth: ChatReadingWidth.maximumWidth(horizontalPadding: 16))
        }
        .task(id: pill?.errorText) {
            guard let text = pill?.errorText else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            dismissedErrors.insert(text)
        }
        .onChange(of: errorTexts) { _, current in dismissedErrors.formIntersection(current) }
        .onChange(of: reader.busy) { _, busy in if busy { dismissedErrors = [] } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingProfile = true } label: {
                    HStack(spacing: 8) {
                        BotRoomAvatars(room: reader.room, roster: roster, avatars: avatars, size: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            if threadID != nil { Text("Thread").font(AppFont.headline()) }
                            Text(reader.room.name).font(threadID == nil ? AppFont.headline() : AppFont.caption()).lineLimit(1)
                        }
                    }
                    .modifier(BotChatTitlePillFallback())
                }
                .accessibilityLabel(reader.room.name)
                .accessibilityHint("Opens this room’s profile.")
            }
            if let stopControl = reader.stopControl {
                ToolbarItem(placement: .topBarTrailing) {
                    stopToolbarButton(stopControl)
                }
            }
        }
        .navigationDestination(isPresented: $showingProfile) {
            BotRoomProfileView(reader: reader, roster: roster, avatars: avatars, hostProfile: hostProfile, onUpdateSignIn: onUpdateSignIn)
        }
        .navigationDestination(item: $selectedThread) { selected in
            BotRoomView(reader: reader, roster: roster, avatars: avatars, hostProfile: hostProfile, threadID: selected,
                        sequence: threadSequence, onUpdateSignIn: onUpdateSignIn)
        }
        .onChange(of: selectedThread) { _, selected in
            if selected == nil { threadSequence = nil }
        }
        .task(id: revision) {
            visible = true
            if scenePhase == .active { await reader.open(owner: owner, preservingLoadedHistory: true) }
        }
        .onChange(of: scenePhase) {
            guard visible else { return }
            switch scenePhase {
            case .background: reader.leave(owner: owner, preservingLoadedHistory: true)
            case .active where reader.link == .idle: revision = UUID()
            default: break
            }
        }
        .onDisappear { visible = false; reader.leave(owner: owner, preservingLoadedHistory: true) }
        .onChange(of: NetworkPathMonitor.shared.changeCount) { if visible { reader.networkPathDidChange() } }
        .onChange(of: reader.feedback) { _, feedback in
            if let feedback { ChatHaptics.botFeedback(feedback.event, isEnabled: isHapticsEnabled) }
        }
        .transcriptLinks()
    }

    private var availableSearchSequence: Int? {
        pendingSequence.flatMap { sequence in reader.events.contains { $0.seq == sequence } ? sequence : nil }
    }

    private var showsThreadOverview: Bool { threadID == nil && !reader.threads.isEmpty }

    private var transcriptEvents: [BotRoomEvent] {
        if let threadID { return reader.threads.first { $0.id == threadID }?.events ?? [] }
        return (reader.events.filter { $0.threadID == nil } + reader.threads.map(\.latest))
            .sorted { $0.seq < $1.seq }
    }

    func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func seedWindow() { window.seed(transcriptEvents, live: reader.link == .live, overview: showsThreadOverview) }

    private func loadEarlier(proxy: ScrollViewProxy) {
        handleFollowEvent(.userScrollBegin)
        let firstEvent = showsThreadOverview ? nil
            : (transcriptEvents.isEmpty ? nil : transcriptEvents[window.start(in: transcriptEvents, overview: showsThreadOverview)])
        let firstShown = firstEvent.map { BotRoomTranscriptRow(event: $0, isOverview: threadID == nil).id }
        Task {
            if !window.showEarlier(in: transcriptEvents, overview: showsThreadOverview) {
                await reader.loadEarlier()
                guard window.showEarlier(in: transcriptEvents, overview: showsThreadOverview) else { return }
            }
            guard let firstShown else { return }
            await Task.yield()
            proxy.scrollTo(firstShown, anchor: .top)
        }
    }

    private func handleFollowEvent(_ event: ChatScrollPolicy.FollowEvent) {
        let next = ChatScrollPolicy.resolveFollow(current: followLatch, event: event)
        if next != followLatch { followLatch = next }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        let wasNearBottom = isNearBottom
        isNearBottom = ChatScrollPolicy.isNearBottom(distanceFromBottom: metrics.distanceFromBottom, isStreaming: false)
        handleFollowEvent(.contentScrolled(
            isAtBottom: ChatScrollPolicy.isAtBottom(distanceFromBottom: metrics.distanceFromBottom),
            isUserScrolling: metrics.isUserInteracting,
            movedAwayFromBottom: metrics.movedAwayFromBottom, wasNearBottom: wasNearBottom))
    }

    private var errorTexts: [String] {
        [reader.commandMessage, reader.errorMessage].compactMap { $0 }
    }

    private var pill: BotComposerPill? {
        BotComposerPill.room(link: reader.link, blocked: reader.status.blocked,
            hasActions: !reader.status.actions.isEmpty, mayRetry: reader.mayResend(in: threadID),
            needsSignIn: reader.needsSignIn, unavailable: reader.runtimeDown,
            errorText: errorTexts.first { !dismissedErrors.contains($0) })
    }

    private func stopToolbarButton(_ control: BotRoomStopControl) -> some View {
        let enabled = control == .stop(enabled: true)
        return Button(role: .destructive) {
            Task { await reader.stop() }
        } label: {
            Group {
                switch control {
                case .stopping:
                    Text("Stopping…").font(AppFont.caption())
                case .stop:
                    Image(systemName: "stop.fill")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
            }
        }
        .tint(.red)
        .disabled(!enabled)
        .accessibilityLabel(control == .stopping ? Text("Stopping…") : Text("Stop every bot in this room"))
    }
}

struct BotRoomTranscriptRow: Identifiable {
    enum ID: Hashable { case thread(String), event(Int) }
    let event: BotRoomEvent
    let isOverview: Bool
    var id: ID {
        if isOverview, let thread = event.threadID { return .thread(thread) }
        return .event(event.seq)
    }
}

struct BotRoomThreadPreview: View {
    let thread: BotRoomThread
    let reader: BotRoomReader
    let rootFiles: String?
    var isPaused = false

    var rootTitle: String? {
        guard let root = thread.root else { return nil }
        let text = root.payload["text"].text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rootFiles {
            return rootFiles
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { author; Spacer(); activity }
                VStack(alignment: .leading) { author; activity }
            }
            .font(AppFont.caption()).foregroundStyle(.appSecondary)
            if isPaused {
                Text("Paused").font(AppFont.caption()).foregroundStyle(.appSecondary)
            }
            if let rootTitle {
                Text(rootTitle).lineLimit(2)
            } else {
                Text("Earlier messages not loaded").foregroundStyle(.appSecondary)
            }
            HStack {
                if thread.root == nil {
                    Text("Loaded replies: \(thread.replyCount)")
                } else {
                    Text("Replies: \(thread.replyCount)")
                }
                Spacer()
                Image(systemName: "chevron.forward").accessibilityHidden(true)
            }
            .font(AppFont.caption()).foregroundStyle(.appSecondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    var authorTitle: String {
        if let root = thread.root { return root.authorName(in: reader.room) }
        return String(localized: "Thread")
    }
    @ViewBuilder private var author: some View {
        Text(verbatim: authorTitle)
    }
    @ViewBuilder private var activity: some View {
        if let time = thread.latest.timestamp, time.isFinite, time > 0 {
            Text(Date(timeIntervalSince1970: time), style: .relative)
        }
    }
}

struct BotRoomTranscriptWindow: Equatable {
    static let pageSize = 50
    private var oldestShown: Int?
    private var overviewCount = Self.pageSize

    func start(in events: [BotRoomEvent], keeping sequence: Int? = nil, overview: Bool = false) -> Int {
        let newestPage = max(0, events.count - Self.pageSize)
        let start = overview ? max(0, events.count - overviewCount) : oldestShown.flatMap { oldest in
            Self.contains(oldest, in: events) ? events.firstIndex { $0.seq >= oldest } : nil
        } ?? newestPage
        guard let sequence, let hit = events.firstIndex(where: { $0.seq == sequence }) else { return start }
        return min(start, hit)
    }

    mutating func seed(_ events: [BotRoomEvent], live: Bool, overview: Bool = false) {
        guard !events.isEmpty else { oldestShown = nil; overviewCount = Self.pageSize; return }
        guard !overview else { return }
        guard live else { return }
        if !(oldestShown.map { Self.contains($0, in: events) } ?? false) {
            oldestShown = events[max(0, events.count - Self.pageSize)].seq
        }
    }

    private static func contains(_ sequence: Int, in events: [BotRoomEvent]) -> Bool {
        guard let first = events.first, let last = events.last else { return false }
        return (first.seq...last.seq).contains(sequence)
    }

    mutating func reveal(_ sequence: Int, in events: [BotRoomEvent], overview: Bool = false) {
        guard !events.isEmpty else { return }
        if overview {
            overviewCount = events.count - start(in: events, keeping: sequence, overview: true)
        } else {
            oldestShown = min(events[start(in: events)].seq, sequence)
        }
    }

    mutating func showEarlier(in events: [BotRoomEvent], overview: Bool = false) -> Bool {
        let start = start(in: events, overview: overview)
        guard start > 0 else { return false }
        if overview {
            overviewCount = events.count - max(0, start - Self.pageSize)
        } else {
            oldestShown = events[max(0, start - Self.pageSize)].seq
        }
        return true
    }
}

private struct BotRoomEventView: View {
    let event: BotRoomEvent
    let files: [BotRoomAttachmentList.File]
    let handoffs: [BotRoomHandoff]
    let reader: BotRoomReader
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let transcriptMediaCacheNamespace: String
    let mayReply: Bool
    var onReply: (() -> Void)? = nil
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey)
    private var showsTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps
    @State private var responseIsVisible = false

    var body: some View {
        if event.kind == "message.user" && !event.isScheduledPost {
            VStack(alignment: .trailing, spacing: 4) {
                if showsMessageText {
                    MessageBubbleView(
                        message: ChatMessage(role: "user", content: event.payload["text"].text,
                            timestamp: event.timestamp, messageId: String(event.seq)),
                        transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                        contextMenuActions: actions,
                        textOnly: true
                    )
                }
                attachments
                footer
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if event.kind == "message.member" || event.isScheduledPost {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 8) {
                    if event.isScheduledPost {
                        BotRoomScheduledPostAvatar(size: 26)
                    } else {
                        BotRoomMemberAvatar(member: event.member(in: reader.room), roster: roster, avatars: avatars, size: 26)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 6) {
                            if event.isScheduledPost {
                                BotRoomScheduledPostHeader(name: event.authorName(in: reader.room))
                            } else {
                                Text(event.sender(in: reader.room)).font(AppFont.caption()).foregroundStyle(.appSecondary)
                            }
                            if showsMessageText { memberMessage }
                        }
                        .accessibilityElement(children: .combine)
                        .chatMessageContextMenu(actions, longPress: false)
                        attachments
                    }
                    Spacer(minLength: 20)
                }
                footer.padding(.leading, 34)
                if !handoffs.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(handoffs.enumerated()), id: \.offset) { _, handoff in
                            Text(handoff.text(in: reader.room))
                                .font(AppFont.caption()).foregroundStyle(.appSecondary)
                                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        } else if let text = event.isRoutingEvent ? event.routingText(in: reader.room) : event.systemText(in: reader.room), !text.isEmpty {
            Text(text).font(AppFont.caption()).foregroundStyle(.appSecondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private var messageText: String { event.payload["text"].text ?? "" }
    private var showsMessageText: Bool {
        files.isEmpty || !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var attachments: some View {
        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
            BotRoomAttachmentCard(file: file, reader: reader,
                                  transcriptMediaCacheNamespace: transcriptMediaCacheNamespace)
        }
    }

    private var memberMessage: some View {
        ResponseTextSelection(identity: messageText, collectsGlyphs: responseIsVisible) {
            MarkdownRenderer(content: messageText)
                .environment(\.markdownTableEdgeFadeColor, nil)
        }
        .onGeometryChange(for: Bool.self) { geometry in
            guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
            return viewport.intersects(CGRect(origin: .zero, size: geometry.size))
        } action: { responseIsVisible = $0 }
        .padding(12).background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var footer: some View {
        let time: String? = if showsTimestamps, let timestamp = event.timestamp, timestamp > 0 {
            ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: timestamp)
        } else {
            nil
        }
        if time != nil || onReply != nil {
            ChatMessageMetaRow(isUserMessage: event.kind == "message.user" && !event.isScheduledPost, timeText: time, onCopy: nil) {
                if let onReply {
                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .chatMinimumHitTarget(
                                horizontalPadding: max(0, (44 - 28) / 2),
                                verticalPadding: max(0, (44 - 28) / 2),
                                in: Rectangle()
                            )
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.chatTactile(.icon))
                    .foregroundStyle(.appSecondary)
                    .disabled(!mayReply)
                    .accessibilityLabel(String(localized: "Reply to \(event.sender(in: reader.room))"))
                }
            }
        }
    }

    private var actions: [ChatMessageActionItem] {
        BotMessageActions.items(
            copyText: messageText,
            isHapticsEnabled: isHapticsEnabled,
            reply: mayReply ? onReply : nil
        )
    }
}

struct BotRoomAvatars: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let size: CGFloat
    var body: some View {
        HStack(spacing: -size * 0.4) {
            ForEach(Array(room.members.prefix(3))) { member in
                BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: size)
            }
            if room.members.isEmpty {
                BotRoomMemberAvatar(member: nil, roster: roster, avatars: avatars, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

struct BotRoomMemberAvatar: View {
    let member: BotGroupRoom.Member?
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let size: CGFloat
    var body: some View {
        let profile = roster.first { $0.id == member?.profile }
        if let profile {
            BotAvatarView(profile: profile, avatar: avatars[profile.id], size: size, motion: .still)
        } else if let placeholder = BotProfile(.object(["name": .string("unknown")])) {
            BotAvatarView(profile: placeholder, avatar: nil, size: size, motion: .still)
        }
    }
}

struct BotRoomWelcomeView: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let showsPrompt: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(room.members) { member in
                        HStack(spacing: 14) {
                            BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: 44)
                            Text(member.name)
                        }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(Self.rows(of: room.members), id: \.startIndex) { row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { member in
                                VStack(spacing: 6) {
                                    BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: 44)
                                    Text(member.name).font(AppFont.caption()).lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: 100)
                            }
                        }
                    }
                }
            }
            if showsPrompt {
                Text("Say something to the group")
                    .font(AppFont.subheadline()).foregroundStyle(.appSecondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let names = room.members.map(\.name).formatted(.list(type: .and))
        return showsPrompt ? String(localized: "Group members: \(names). Say something to the group.")
            : String(localized: "Group members: \(names).")
    }

    private static func rows(of members: [BotGroupRoom.Member]) -> [ArraySlice<BotGroupRoom.Member>] {
        guard !members.isEmpty else { return [] }
        let rowCount = (members.count + 2) / 3
        let perRow = (members.count + rowCount - 1) / rowCount
        return stride(from: 0, to: members.count, by: perRow).map { members[$0..<min($0 + perRow, members.count)] }
    }
}

struct BotRoomInboxRow: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    var body: some View {
        HStack(spacing: 14) {
            BotRoomAvatars(room: room, roster: roster, avatars: avatars, size: 32).frame(width: 44)
            Text(room.name).font(AppFont.headline())
            Spacer(minLength: 8)
            if let date = room.updatedAt {
                Text(BotInboxDateLabel.text(for: date)).font(AppFont.subheadline()).foregroundStyle(.appSecondary)
            }
        }
        .padding(.vertical, 12)
        // A room row has no preview line, so without this only the name and avatars take taps.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
