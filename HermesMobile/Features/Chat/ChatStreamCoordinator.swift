import Foundation
import Observation
import OSLog
import SwiftData

private let chatStreamCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatStreamCoordinator"
)

struct ChatStreamCoordinatorTiming: Equatable {
    let checkingInterval: TimeInterval
    let reconnectInterval: TimeInterval
    let runningToolReconnectInterval: TimeInterval
    let statusPollCooldown: TimeInterval
    // Transport quieter than this is treated as provably alive; must sit above
    // the server's ~5s SSE heartbeat cadence and below reconnectInterval (#227).
    let transportFreshInterval: TimeInterval

    static let standard = ChatStreamCoordinatorTiming(
        checkingInterval: 5,
        reconnectInterval: 18,
        runningToolReconnectInterval: 25,
        statusPollCooldown: 4,
        transportFreshInterval: 12
    )
}

struct ChatStreamLoadPreparation: Equatable {
    let activeStreamIDBeforeLoad: String?
    let shouldPrepareSuspendedStreamResume: Bool
}

@MainActor
protocol ChatStreamCoordinatorDelegate: AnyObject {
    var streamCoordinatorSessionID: String? { get }
    var streamCoordinatorDisplayTitle: String { get }
    var streamCoordinatorHasRunningLiveToolCall: Bool { get }
    var streamCoordinatorHasPendingPrompt: Bool { get }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool { get }
    var streamCoordinatorStreamingAssistantMessageID: String? { get set }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async
    func streamCoordinatorLatestAssistantMessageID() -> String?
    func streamCoordinatorStartAuxiliaryMonitoring()
    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool)
    func streamCoordinatorSaveSnapshotIfNeeded()
    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String?
    func streamCoordinatorRemoveSnapshot(streamID: String?)
    func streamCoordinatorFlushPinnedLocalNoticesToTranscript()
    func streamCoordinatorDrainQueuedSlashMessageIfIdle()
    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool)
    func streamCoordinatorDidFinishStream()
    func streamCoordinatorDidReceiveErrorMessage(_ message: String)
    /// A non-fatal `warning` frame — the model was swapped for a fallback, or
    /// approvals aren't available on this run. Inline notice, not an error (#7).
    func streamCoordinatorDidReceiveWarningMessage(_ message: String)
    /// Re-read the transcript from the server. Used on the error path, where
    /// the server has already stored the explanation the stream did not show.
    func streamCoordinatorRequestTranscriptReload()
    func streamCoordinatorDidReceiveRecoveryError(_ error: Error)
    /// The live connection just proved itself healthy — real stream progress, or
    /// a status call the server answered. Retracts a stale recovery warning
    /// without waiting for another send (#207).
    func streamCoordinatorDidConfirmConnectionHealth()
    func streamCoordinatorDidStartConnection(isReplay: Bool)
    func streamCoordinatorDidResetRecoveryState()

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool
    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse)
    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse)
    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool
    func streamCoordinatorApplyGoalStatus(_ payload: GoalStreamEvent)
    @discardableResult
    func streamCoordinatorEnqueueGoalContinuation(_ payload: GoalStreamEvent) -> Bool
    /// Auto-compression moved the conversation onto a new session id; rebind to
    /// it so later writes don't land in the archived parent snapshot (#2).
    func streamCoordinatorApplySessionCompressed(_ payload: SessionCompressedStreamEvent)
}

@MainActor
@Observable
final class ChatStreamCoordinator {
    @ObservationIgnored private weak var delegate: (any ChatStreamCoordinatorDelegate)?
    private let client: APIClient
    private let streamClient: SSEStreamingClient
    private let liveActivityManager: any AgentLiveActivityManaging
    private let timing: ChatStreamCoordinatorTiming
    private var showsLiveActivityResponseExcerpts: Bool

    private(set) var activeStreamID: String?
    private(set) var recoveryState: ActiveStreamRecoveryState = .idle
    private(set) var isConnectionSuspended = false
    private(set) var hasCompletedCurrentResponse = false
    private(set) var lastEventID: String?
    private(set) var lastProgressDate: Date?
    private(set) var lastTransportActivityDate: Date?
    private(set) var liveTokensPerSecond: Double?
    private var lastRecoveryStatusCheckDate: Date?
    private(set) var isReplayConnection = false
    // Bumped whenever the active run starts or finalizes. Captured before an async
    // transcript load so a concurrent cancel/completion during the load can't be
    // double-finalized (PR #266 review #2).
    private var runGeneration = 0

    init(
        client: APIClient,
        streamClient: SSEStreamingClient,
        liveActivityManager: any AgentLiveActivityManaging,
        showsLiveActivityResponseExcerpts: Bool,
        timing: ChatStreamCoordinatorTiming = .standard
    ) {
        self.client = client
        self.streamClient = streamClient
        self.liveActivityManager = liveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.timing = timing
    }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        if !shows, activeStreamID != nil {
            liveActivityManager.update(.clearResponseExcerpt)
        }
    }

    func prepareForNewResponse() {
        hasCompletedCurrentResponse = false
        isConnectionSuspended = false
        liveTokensPerSecond = nil
    }

    /// `resumesFromLastEvent` lets a caller reuse this connection's own cursor
    /// when it has one and the caller has no explicit `replayAfterSeq`. Only the
    /// rejoin-an-active-run path opts in: elsewhere the server has already said
    /// there is no journal to replay, and asking anyway is a wasted request.
    func start(
        streamID: String,
        replayAfterSeq: Int? = nil,
        resumesFromLastEvent: Bool = false,
        recoveryState: ActiveStreamRecoveryState = .idle
    ) {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil
        runGeneration &+= 1
        // A cursor only means something within its own run, so moving to a
        // different stream drops it. Staying on the same one keeps it: that is
        // what lets a resume pick up where this client stopped instead of
        // re-reading the whole journal.
        let isSameRun = activeStreamID == streamID
        activeStreamID = streamID
        isConnectionSuspended = false
        if !isSameRun, replayAfterSeq == nil {
            lastEventID = nil
        }

        // Resume from this connection's own cursor when it has one. Rejoining a
        // run that is still going used to drop it and attach bare, so the server
        // pushed only what happened from that moment on and everything produced
        // while the app was backgrounded never arrived (#8).
        //
        // No cursor means no replay at all. Asking the server to replay a run
        // this client never streamed would rebuild it on top of a transcript
        // that has no in-flight assistant message to merge into, which
        // duplicates content — the reference client only gets away with it by
        // rendering the run-journal snapshot first. That is a larger change than
        // this one and is deliberately left out.
        let resumeEventID = (replayAfterSeq != nil || resumesFromLastEvent) ? lastEventID : nil
        let resumeAfterSeq = replayAfterSeq
            ?? (resumesFromLastEvent ? Self.runJournalReplayAfterSeq(from: resumeEventID) : nil)

        markConnectionStarted(
            isReplay: resumeAfterSeq != nil,
            recoveryState: recoveryState
        )
        startLiveActivity(streamID: streamID)
        streamClient.start(
            url: client.chatStreamURL(
                streamID: streamID,
                replayAfterSeq: resumeAfterSeq,
                replayAfterEventID: resumeEventID
            )
        ) { [weak self] event in
            self?.handle(event)
        }
        delegate?.streamCoordinatorStartAuxiliaryMonitoring()
    }

    func cancelActiveStream() async throws -> ChatCancelResponse? {
        guard let activeStreamID else { return nil }

        let response = try await client.cancelChat(streamID: activeStreamID)
        guard self.activeStreamID == activeStreamID else { return response }
        guard response.ok != false else { return response }

        liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        finishStream()
        return response
    }

    func suspendActiveStreamConnection() {
        guard activeStreamID != nil, !hasCompletedCurrentResponse, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
    }

    func prepareForSessionLoad() -> ChatStreamLoadPreparation {
        liveTokensPerSecond = nil
        let activeStreamIDBeforeLoad = activeStreamID
        if activeStreamIDBeforeLoad != nil, !hasCompletedCurrentResponse {
            delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        }

        return ChatStreamLoadPreparation(
            activeStreamIDBeforeLoad: activeStreamIDBeforeLoad,
            shouldPrepareSuspendedStreamResume: activeStreamID == nil || isConnectionSuspended
        )
    }

    func reconcileSessionLoad(
        loadedActiveStreamID rawLoadedActiveStreamID: String?,
        preparation: ChatStreamLoadPreparation,
        usedCacheFallback: Bool
    ) {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil

        if usedCacheFallback {
            activeStreamID = nil
            isConnectionSuspended = false
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            resetRecoveryState()
            return
        }

        let loadedActiveStreamID = rawLoadedActiveStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparation.shouldPrepareSuspendedStreamResume {
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            if let streamID = loadedActiveStreamID, !streamID.isEmpty {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                isConnectionSuspended = true
                restoreSnapshotIfAvailable(streamID: streamID)
            } else {
                activeStreamID = nil
                isConnectionSuspended = false
                resetRecoveryState()
            }
        } else {
            let streamID = loadedActiveStreamID?.isEmpty == false
                ? loadedActiveStreamID
                : preparation.activeStreamIDBeforeLoad
            if let streamID {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                restoreSnapshotIfAvailable(streamID: streamID)
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
            }
            isConnectionSuspended = false
        }
    }

    func reconnectIfNeeded(modelContext: ModelContext? = nil) async {
        guard let activeStreamID, isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: activeStreamID)
            // The server answered, so whatever recovery warning is on screen is
            // stale even if this run turns out to be over (#207).
            delegate?.streamCoordinatorDidConfirmConnectionHealth()
            guard self.activeStreamID == activeStreamID, isConnectionSuspended else { return }

            if response.active == true {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard self.activeStreamID == activeStreamID, isConnectionSuspended else { return }

                let streamIDToResume = activeStreamID
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    restoreSnapshotIfAvailable(streamID: streamIDToResume)
                }
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
                isConnectionSuspended = false
                start(streamID: streamIDToResume, resumesFromLastEvent: true)
            } else if response.replayAvailable == true {
                let replayAfterSeq = Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0
                self.activeStreamID = activeStreamID
                isConnectionSuspended = false
                start(streamID: activeStreamID, replayAfterSeq: replayAfterSeq)
            } else {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                // Bail if a concurrent completion/cancel/new run finalized or
                // replaced this run during the load (see canFinalizeRunAfterLoad).
                guard canFinalizeRunAfterLoad(streamID: activeStreamID, capturedGeneration: generation) else { return }

                // #246: the server reports the run is over. Finalize it (and end
                // the Live Activity) instead of re-arming and leaving it dangling
                // on "running" when no assistant reply surfaced.
                finalizeInactiveStream(streamID: activeStreamID)
            }
        } catch {
            if (error as? APIError)?.indicatesMissingStream == true,
               self.activeStreamID == activeStreamID,
               isConnectionSuspended {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: activeStreamID, capturedGeneration: generation) else { return }
                finalizeInactiveStream(streamID: activeStreamID)
                return
            }
            delegate?.streamCoordinatorDidReceiveRecoveryError(error)
        }
    }

    func refreshTranscriptIfCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard response.active == false else { return }

            await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
            // Bail if a concurrent completion/cancel/new run finalized or replaced
            // this run during the load (see canFinalizeRunAfterLoad).
            guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation) else { return }

            guard delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true else {
                // Foreground safety net: the live SSE is still connected and owns
                // completion, so a status poll that briefly reports inactive must
                // not finalize the run — keep waiting for the real `.done`. (This
                // is why #246's finalize-on-reopen fix deliberately excludes this
                // path; see finalizeInactiveStream.)
                activeStreamID = expectedStreamID
                isConnectionSuspended = false
                return
            }

            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: expectedStreamID)
        } catch {
            // This is a foreground safety net. The primary SSE path owns visible
            // stream errors; a failed status poll should not interrupt it.
            chatStreamCoordinatorLogger.warning(
                "Active stream status refresh failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    func recoverStaleStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        guard let activeStreamID,
              !isConnectionSuspended,
              !hasCompletedCurrentResponse
        else {
            recoveryState = .idle
            return
        }

        guard delegate?.streamCoordinatorHasPendingPrompt != true else {
            recoveryState = .idle
            return
        }

        let reconnectInterval = delegate?.streamCoordinatorHasRunningLiveToolCall == true
            ? timing.runningToolReconnectInterval
            : timing.reconnectInterval
        guard let lastProgressDate else {
            guard let lastTransportActivityDate,
                  now.timeIntervalSince(lastTransportActivityDate) >= reconnectInterval
            else {
                recoveryState = .idle
                return
            }

            recoveryState = .checking
            lastRecoveryStatusCheckDate = now
            await recoverStaleStream(
                streamID: activeStreamID,
                forceReconnect: true,
                modelContext: modelContext
            )
            return
        }

        let elapsed = now.timeIntervalSince(lastProgressDate)
        guard elapsed >= timing.checkingInterval else {
            recoveryState = .idle
            return
        }

        let transportElapsed = now.timeIntervalSince(lastTransportActivityDate ?? lastProgressDate)
        guard transportElapsed >= timing.transportFreshInterval else {
            // #227: heartbeats prove the connection is alive during a
            // semantically quiet window (model thinking / slow tool call), so
            // stay idle and skip status polls. A genuinely silent transport
            // still escalates below once past transportFreshInterval.
            recoveryState = .idle
            return
        }

        recoveryState = .checking
        let shouldForceReconnect = transportElapsed >= reconnectInterval
        guard shouldForceReconnect || shouldPollStatus(now: now) else { return }

        lastRecoveryStatusCheckDate = now
        await recoverStaleStream(
            streamID: activeStreamID,
            forceReconnect: shouldForceReconnect,
            modelContext: modelContext
        )
    }

    func markProgress(now: Date = Date()) {
        lastProgressDate = now
        lastTransportActivityDate = now
        lastRecoveryStatusCheckDate = nil
        recoveryState = .idle
        delegate?.streamCoordinatorDidConfirmConnectionHealth()
    }

    func clearReplayConnection() {
        isReplayConnection = false
    }

    nonisolated static func runJournalReplayAfterSeq(from eventID: String?) -> Int? {
        guard let eventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty
        else {
            return nil
        }

        let sequenceText: Substring
        if let delimiterIndex = eventID.lastIndex(of: ":") {
            sequenceText = eventID[eventID.index(after: delimiterIndex)...]
        } else {
            sequenceText = Substring(eventID)
        }

        guard let sequence = Int(sequenceText) else {
            return nil
        }

        return max(0, sequence)
    }

    private func handle(_ event: SSEEvent) {
        lastEventID = streamClient.lastEventID ?? lastEventID
        lastTransportActivityDate = Date()

        switch event {
        case .token(let text):
            if showsLiveActivityResponseExcerpts {
                liveActivityManager.update(.token(text))
            }
            if delegate?.streamCoordinatorAppendToken(text) == true {
                markProgress()
            }
        case .interimAssistant(let payload):
            if showsLiveActivityResponseExcerpts,
               payload.alreadyStreamed != true,
               let text = payload.text {
                liveActivityManager.update(.interimAssistant(text))
            }
            if delegate?.streamCoordinatorAppendInterimAssistant(payload) == true {
                markProgress()
            }
        case .reasoning(let text):
            liveActivityManager.update(.reasoning(text))
            if delegate?.streamCoordinatorAppendReasoning(text) == true {
                markProgress()
            }
        case .toolStarted(let payload):
            liveActivityManager.update(.toolStarted(name: payload.name))
            if delegate?.streamCoordinatorAppendToolCall(payload) == true {
                markProgress()
            }
        case .toolCompleted(let payload):
            liveActivityManager.update(.toolCompleted)
            if delegate?.streamCoordinatorCompleteToolCall(payload) == true {
                markProgress()
            }
        case .title(let payload):
            if delegate?.streamCoordinatorUpdateTitle(payload) == true {
                markProgress()
            }
        case .metering(let payload):
            guard payload.sessionId == nil || payload.sessionId == delegate?.streamCoordinatorSessionID else {
                break
            }
            liveTokensPerSecond = payload.displayableTokensPerSecond
        case .done(let payload):
            let hasCompletedTranscript = delegate?.streamCoordinatorApplyDone(payload) == true
            completeCurrentResponse(needsTranscriptRefresh: !hasCompletedTranscript)
        case .approvalPending(let update):
            liveActivityManager.update(.waitingForApproval)
            delegate?.streamCoordinatorApplyApprovalUpdate(update)
            markProgress()
        case .clarificationPending(let update):
            liveActivityManager.update(.waitingForClarification)
            delegate?.streamCoordinatorApplyClarificationUpdate(update)
            markProgress()
        case .pendingSteerLeftover(let text):
            if delegate?.streamCoordinatorEnqueuePendingSteerLeftover(text) == true {
                markProgress()
            }
        case .goalStatus(let payload):
            delegate?.streamCoordinatorApplyGoalStatus(payload)
            // Evaluating a goal can take a while; count it as progress so the
            // stale-stream recovery doesn't fire mid-evaluation.
            markProgress()
        case .goalContinue(let payload):
            if delegate?.streamCoordinatorEnqueueGoalContinuation(payload) == true {
                markProgress()
            }
        case .sessionCompressed(let payload):
            delegate?.streamCoordinatorApplySessionCompressed(payload)
            // Compressing a long transcript takes a while and emits no tokens;
            // treat the frame as progress so stale-stream recovery holds off.
            markProgress()
        case .streamEnd:
            if !hasCompletedCurrentResponse {
                liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
            }
            finishStream()
        case .cancelled:
            liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
            finishStream()
        case .error(let payload):
            handleErrorEvent(payload)
        case .warning(let payload):
            // Non-fatal by contract: the stream keeps producing tokens, so this
            // must not finish it. It does prove the transport is alive, so it
            // clears a "checking" chip the same way a heartbeat does.
            if recoveryState == .checking {
                recoveryState = .idle
            }
            if let message = payload.displayMessage {
                delegate?.streamCoordinatorDidReceiveWarningMessage(message)
            }
        case .transportError(let message):
            handleTransportError(message)
        case .heartbeat:
            // #227: a heartbeat proves the transport is alive without carrying
            // semantic progress — drop an already-shown "Checking stream" state
            // immediately. Never demote .reconnecting; that chip is owned by
            // the reconnect flow until real progress lands.
            if recoveryState == .checking {
                recoveryState = .idle
            }
        case .ignored:
            break
        }
    }

    /// Handles an `error` / `apperror` frame.
    ///
    /// Two parts of the payload used to be thrown away with the rest of it.
    ///
    /// `recovery_control` marks a frame that is not an error report at all: it
    /// exists to make the client rebuild its transcript (`api/run_journal.py:760`
    /// and `api/routes.py:17461` @ 399cd7ab), and the reference client answers
    /// it by reloading and showing nothing. Rendering it as a red line told the
    /// user something had gone wrong when nothing had.
    ///
    /// And every error frame's text is appended to the stored session before it
    /// is sent (`api/streaming.py:10195`), so reloading is what actually puts
    /// the explanation in the transcript. Without it the view kept whatever
    /// half-streamed content was on screen and the real message stayed
    /// invisible until the user happened to pull to refresh (#6).
    private func handleErrorEvent(_ payload: ErrorStreamEvent) {
        // The error path carries a compression rotation too, so follow it here
        // as well or the retry after the failure writes to the archived parent.
        if let rotatedSessionID = payload.session?.sessionId {
            delegate?.streamCoordinatorApplySessionCompressed(
                SessionCompressedStreamEvent(newSessionId: rotatedSessionID)
            )
        }

        if payload.isRecoveryControl {
            liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
            delegate?.streamCoordinatorRequestTranscriptReload()
            finishStream()
            return
        }

        if !hasCompletedCurrentResponse {
            delegate?.streamCoordinatorDidReceiveErrorMessage(
                payload.displayMessage(fallback: String(localized: "The stream returned an error."))
            )
        }
        liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
        delegate?.streamCoordinatorRequestTranscriptReload()
        finishStream()
    }

    private func handleTransportError(_ message: String) {
        liveTokensPerSecond = nil
        guard activeStreamID != nil, !hasCompletedCurrentResponse else {
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            finishStream()
            return
        }

        guard !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)

        Task { @MainActor [weak self] in
            await self?.reconnectIfNeeded()
        }
    }

    private func shouldPollStatus(now: Date) -> Bool {
        guard let lastRecoveryStatusCheckDate else { return true }

        return now.timeIntervalSince(lastRecoveryStatusCheckDate) >= timing.statusPollCooldown
    }

    private func recoverStaleStream(
        streamID expectedStreamID: String,
        forceReconnect: Bool,
        modelContext: ModelContext?
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            delegate?.streamCoordinatorDidConfirmConnectionHealth()
            guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }

            if response.active == false {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                // Same generation/clobber guard as the reconnect and refresh paths;
                // the extra `!isConnectionSuspended` keeps the reconnect path owning
                // a stream that was suspended mid-load. (PR #266 review #3)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }

                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // PR #238 review: recoveryState was set to .checking before this
            // await. If it changed mid-flight (a heartbeat or real progress
            // demoted it to .idle), the transport just proved itself alive —
            // don't resurrect the chip or churn a live connection; the next
            // recovery tick re-evaluates from scratch.
            guard recoveryState == .checking, forceReconnect else { return }

            reconnectStaleStream(
                streamID: expectedStreamID,
                usesReplay: response.replayAvailable == true
            )
        } catch {
            chatStreamCoordinatorLogger.warning(
                "Stale stream recovery status check failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )

            if (error as? APIError)?.indicatesMissingStream == true,
               activeStreamID == expectedStreamID,
               !isConnectionSuspended {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }
                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // Same mid-flight demotion guard as the success path (PR #238
            // review): only a still-.checking state may escalate.
            guard recoveryState == .checking,
                  forceReconnect,
                  activeStreamID == expectedStreamID,
                  !isConnectionSuspended
            else { return }

            reconnectStaleStream(streamID: expectedStreamID, usesReplay: true)
        }
    }

    private func reconnectStaleStream(streamID: String, usesReplay: Bool) {
        guard activeStreamID == streamID, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        let replayAfterSeq = usesReplay ? Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0 : nil
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        recoveryState = .reconnecting
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        start(
            streamID: streamID,
            replayAfterSeq: replayAfterSeq,
            recoveryState: .reconnecting
        )
    }

    private func completeCurrentResponse(needsTranscriptRefresh: Bool) {
        runGeneration &+= 1
        liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: activeStreamID)
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = true
        delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: needsTranscriptRefresh)
        resetRecoveryState()
    }

    private func completeResponseFromRefreshedTranscriptAndFinishStream(streamID completedStreamID: String?) {
        completeCurrentResponse(needsTranscriptRefresh: false)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: completedStreamID)
        finishStream()
    }

    /// Whether `self` may still finalize the run captured before an awaited
    /// transcript load. Returns false (bail) when a concurrent completion / cancel
    /// / new run bumped the generation — finalizing would double-finalize — or when
    /// a *different* run is now active — finalizing would clobber the newer stream.
    /// A run reconciled to `nil` during the load still passes: it should be
    /// finalized from the refreshed transcript so its Live Activity can't dangle on
    /// "running" (#246). Shared by all three post-load finalize paths
    /// (reconnect-after-suspend, foreground refresh, stale recovery) so they stay in
    /// lockstep — recoverStaleStream previously used a stricter, hand-rolled guard.
    /// (PR #266 review #3)
    private func canFinalizeRunAfterLoad(streamID: String, capturedGeneration: Int) -> Bool {
        guard runGeneration == capturedGeneration else { return false }
        return activeStreamID == nil || activeStreamID == streamID
    }

    /// The server reports this stream is no longer active. Complete from the
    /// just-refreshed transcript when an assistant reply surfaced, otherwise
    /// finalize as failed. Either branch ends the Live Activity, so it can never
    /// dangle on "running" after the run is over (#246). Shared by the two paths
    /// with no live SSE behind them — reconnect-after-suspend and stale recovery.
    /// The foreground transcript-refresh safety net deliberately keeps waiting
    /// instead, because its live SSE still owns completion.
    private func finalizeInactiveStream(streamID: String?) {
        if delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true {
            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: streamID)
        } else {
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        }
    }

    private func finishStream() {
        runGeneration &+= 1
        let completedNormally = hasCompletedCurrentResponse
        let finishedStreamID = activeStreamID
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorRemoveSnapshot(streamID: finishedStreamID)
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = false
        delegate?.streamCoordinatorDidFinishStream()
        isConnectionSuspended = false
        resetRecoveryState()
        delegate?.streamCoordinatorDrainQueuedSlashMessageIfIdle()
        if completedNormally {
            delegate?.streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
        }
    }

    private func markConnectionStarted(
        isReplay: Bool,
        recoveryState: ActiveStreamRecoveryState
    ) {
        let startedAt = Date()
        lastProgressDate = isReplay ? startedAt : nil
        lastTransportActivityDate = startedAt
        lastRecoveryStatusCheckDate = nil
        self.recoveryState = recoveryState
        isReplayConnection = isReplay
        delegate?.streamCoordinatorDidStartConnection(isReplay: isReplay)
    }

    private func resetRecoveryState() {
        recoveryState = .idle
        lastProgressDate = nil
        lastTransportActivityDate = nil
        lastRecoveryStatusCheckDate = nil
        isReplayConnection = false
        delegate?.streamCoordinatorDidResetRecoveryState()
    }

    private func startLiveActivity(streamID: String) {
        guard let sessionID = delegate?.streamCoordinatorSessionID else { return }

        liveActivityManager.start(
            sessionID: sessionID,
            sessionTitle: delegate?.streamCoordinatorDisplayTitle ?? String(localized: "Untitled Session"),
            streamID: streamID
        )
    }

    private func restoreSnapshotIfAvailable(streamID: String) {
        guard lastEventID == nil else {
            _ = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID)
            return
        }

        lastEventID = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID) ?? lastEventID
    }
}
