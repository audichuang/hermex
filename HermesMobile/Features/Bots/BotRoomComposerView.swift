import SwiftUI

/// The Bot editor and mention panel, with only the controls rooms support.
struct BotRoomComposerView: View {
    @Bindable var reader: BotRoomReader
    var threadID: String? = nil
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(AppAppearanceSettings.accentHexKey) private var accentHex: String?
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = ComposerSelection()
    @State private var focused = false
    @State private var inputHeight: CGFloat = 22
    @State private var measuredHeight: CGFloat = 0
    /// Dictation as in a Bot Chat: a tap on the mic, words land in this thread's draft.
    /// Rooms take no voice notes, since a room message is text only.
    @State private var voiceInput = ComposerVoiceInputController()
    @State private var restoresFocusAfterDictation = false
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 16

    /// The draft stays locked from the mic tap until the words have landed.
    private var isDictating: Bool { voiceInput.state != .idle }

    var body: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 8) {
                if !isDictating, let error = voiceInput.errorMessage {
                    ComposerVoiceStatusView(status: ComposerVoiceStatus(text: error, systemImage: "exclamationmark.triangle", isError: true),
                                            onDismiss: voiceInput.dismissError)
                }
                if focused, !isDictating, reader.mayEditDraft(in: threadID),
                   let trigger = BotMentionTrigger.detect(in: reader.draft(in: threadID), selection: selection.range) {
                    let completions = BotRoomMentions.completions(room: reader.room, query: trigger.query)
                    if !completions.isEmpty {
                        BotMentionAutocompleteView(completions: completions, avatars: avatars, room: reader.room, roster: roster) { item in
                            let result = trigger.applying(tag: item.tag, to: reader.draft(in: threadID))
                            reader.setDraft(result.draft, in: threadID)
                            selection = selection.moved(to: result.selection)
                            ChatHaptics.autocompleteAccepted(isEnabled: isHapticsEnabled)
                        }
                        .layoutPriority(-1)
                    }
                }
                HStack(spacing: 4) {
                    ComposerTextInputView(
                        text: Binding(get: { reader.draft(in: threadID) }, set: { reader.setDraft($0, in: threadID) }), selection: $selection, isFocused: $focused,
                        inputHeight: $inputHeight, measuredHeight: $measuredHeight,
                        isDisabled: !reader.mayEditDraft(in: threadID) || isDictating, isCollapsed: !(focused || isDictating),
                        // Send only: a room has no send choices, and its Stop halts every bot in it.
                        keyboardCommands: ComposerKeyboardCommands(send: reader.maySend(in: threadID) && !isDictating
                            ? .init(title: String(localized: "Send Message"), perform: send) : nil),
                        verticalPadding: 12, chipSkills: [], chipFilePaths: [], quotes: [],
                        onPasteFileProviders: { _ in }, onPasteFileURLs: { _ in },
                        onPasteImageProviders: { _ in }, onPasteImages: { _ in },
                        onTapChip: { _ in }, onTapQuote: { _ in }, onRemoveQuote: { _ in },
                        placeholder: threadID == nil ? String(localized: "Message \(reader.room.name)") : String(localized: "Reply in thread"), acceptsAttachments: false
                    )
                    if !isDictating {
                        ComposerVoiceControlButton(
                            isDisabled: !reader.mayEditDraft(in: threadID) || voiceInput.isRequestingPermission,
                            color: Color(.appTextSecondary), isRecordingVoiceNote: false, supportsVoiceNotes: false,
                            onTap: toggleVoiceInput, onRecordingStart: {}, onRecordingDragChanged: { _ in }, onRecordingEnd: { _ in })
                        actionButton
                    }
                }
                .padding(ChatComposerMetrics.pillInset)
                .modifier(ChatComposerSurfaceStyle(isExpanded: focused || isDictating))
                if isDictating {
                    let finish = ChatComposerActionAppearance(isStop: false, isDisabled: false,
                        colorScheme: colorScheme, tintsPrimaryActions: tintsPrimaryActions,
                        tint: PrimaryActionTintSettings.colors(accentHex: accentHex, serverHex: themeHex))
                    ComposerDictationRow(voiceInput: voiceInput, circleSize: ChatComposerMetrics.actionSize,
                                         finishBackground: finish.background, finishForeground: finish.foreground)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDictating)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .task(id: AppLock.shared.isLocked) {
            // Dictation waits for the app lock, as in a Bot Chat (#885).
            if AppLock.shared.isLocked { voiceInput.suspend() } else if scenePhase == .active { voiceInput.resume() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { voiceInput.resume() } else { voiceInput.suspend() }
        }
        .onChange(of: threadID) { _, _ in stopDictation() }
        .onChange(of: isDictating) { _, dictating in if !dictating { restoreFocusAfterDictation() } }
        .onDisappear(perform: stopDictation)
    }

    private func toggleVoiceInput() {
        voiceInput.transcribe = HermesTranscription.transcriber(forRoomOn: reader.connection, server: reader.key.server)
        voiceInput.providerPreference = ComposerSTTProviderPreference.storedValue(sttProviderPreferenceRawValue)
        // Resign first: a live composition commits as the editor lets go, and dictation's
        // baseline has to include that edit.
        restoresFocusAfterDictation = focused
        if focused {
            UIApplication.shared.sendAction(#selector(ComposerChipTextView.resignForDictation), to: nil, from: nil, for: nil)
            focused = false
        }
        let thread = threadID
        let start = voiceInput.scheduleToggle(
            draftState: { ComposerVoiceDraftState(text: reader.draft(in: thread), selection: selection) },
            updateDraft: { update in
                reader.setDraft(update.text, in: thread)
                selection = selection.moved(to: update.caret)
            }
        )
        Task {
            await start.value
            if !isDictating { restoreFocusAfterDictation() }
        }
    }

    private func restoreFocusAfterDictation() {
        guard restoresFocusAfterDictation else { return }
        restoresFocusAfterDictation = false
        focused = true
    }

    private func stopDictation() {
        restoresFocusAfterDictation = false
        voiceInput.stopBeforeSubmittingDraft()
    }

    private var actionButton: some View {
        let stop = reader.showsStop
        let enabled = stop ? reader.mayStop : reader.maySend(in: threadID)
        let appearance = ChatComposerActionAppearance(isStop: stop, isDisabled: !enabled,
            colorScheme: colorScheme, tintsPrimaryActions: tintsPrimaryActions,
            tint: PrimaryActionTintSettings.colors(accentHex: accentHex, serverHex: themeHex))
        return Button {
            if stop { Task { await reader.stop() } } else { send() }
        } label: {
            Group {
                if reader.awaitingStop || reader.status.stopping > 0 {
                    Text("Stopping…").font(AppFont.caption()).padding(.horizontal, 8)
                } else {
                    Image(systemName: stop ? "stop.fill" : "arrow.up")
                        .font(.system(size: iconSize, weight: .semibold))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: ChatComposerMetrics.actionSize)
                }
            }
            .frame(minHeight: ChatComposerMetrics.actionSize)
            .background(appearance.background).foregroundStyle(appearance.foreground).clipShape(Capsule())
        }
        .buttonStyle(.chatTactile(.icon)).disabled(!enabled)
        .accessibilityLabel(stop ? Text("Stop every bot in this room") : Text("Send"))
    }

    private func send() { Task { await reader.send(threadID: threadID) } }
}

/// Room handles are server routing keys. Friendly names only help searching;
/// unlike a bot's chat, room sends must never append an identification annotation.
enum BotRoomMentions {
    static func completions(room: BotGroupRoom, query: String) -> [BotMentions.Completion] {
        let members = room.members.compactMap { member -> BotMentions.Completion? in
            guard let handle = member.handle, !handle.isEmpty,
                  let profile = BotProfile(.object(["name": .string(member.id), "display_name": .string(member.name)])) else { return nil }
            return BotMentions.Completion(profile: profile, tag: handle)
        }
        let everyone = ["all", "everyone"].compactMap { tag -> BotMentions.Completion? in
            guard let profile = BotProfile(.object(["name": .string("room-mention:" + tag),
                "display_name": .string(String(localized: "Everyone"))])) else { return nil }
            return BotMentions.Completion(profile: profile, tag: tag)
        }
        return Array((members + everyone).filter {
            query.isEmpty || $0.tag.localizedStandardContains(query) || $0.profile.name.localizedStandardContains(query)
        }.prefix(8))
    }
}

struct BotRoomActionCard: View {
    let reader: BotRoomReader
    let action: BotRoomAction
    /// The action whose Discard is being confirmed, kept apart from `action`: the room's cards are
    /// keyed by position, so a poll can hand this card another task while the sheet is open.
    @State private var confirmingDiscard: BotRoomAction?
    var body: some View {
        if let approval = action.approval {
            BotPendingRequestCard(request: .approval(approval), identity: identity,
                isEnabled: reader.mayAct(action), canStop: reader.mayStop,
                isAnswering: reader.busy && reader.inactiveActions.contains(action.id), resolution: nil,
                onApprove: { choice in Task { await reader.act(action, choice: choice) } },
                onAnswer: { _ in }, onSkip: {}, onCredential: { _ in },
                onStop: { Task { await reader.stop() } }, onConnection: { _ in },
                summary: reader.summaryPresentation(for: action))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(identity).font(AppFont.caption()).foregroundStyle(.appSecondary)
                if action.isRetry {
                    Button("Retry") { Task { await reader.act(action) } }.disabled(!reader.mayAct(action))
                } else if action.isDiscard {
                    // A canonical host lost this task's reply in a restart (#1605); discarding is permanent.
                    Text("Hermes restarted while this bot was replying, so its reply is lost.")
                        .font(AppFont.callout())
                    Button("Discard", role: .destructive) { confirmingDiscard = action }
                        .disabled(!reader.mayAct(action))
                        .confirmationDialog("Discard this reply?", isPresented: Binding(
                            get: { confirmingDiscard != nil }, set: { if !$0 { confirmingDiscard = nil } }),
                            titleVisibility: .visible, presenting: confirmingDiscard) { confirmed in
                            Button("Discard", role: .destructive) { Task { await reader.act(confirmed) } }
                            Button("Cancel", role: .cancel) {}
                        } message: { _ in
                            Text("The bot won’t finish it, and it isn’t retried. The group carries on.")
                        }
                } else {
                    Label("Needs attention. Answer the request in Hermes Desktop on this same connection.", systemImage: "desktopcomputer")
                        .font(AppFont.callout())
                }
            }
            .padding(16).frame(maxWidth: 560, alignment: .leading)
            .pendingRequestCardSurface(cornerRadius: BotPendingRequestCard.cornerRadius)
        }
    }
    private var identity: String {
        let member = reader.room.members.first { $0.id == action.id.member }
        return [member?.name, reader.room.name, reader.connection.name].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The one thing worth a pill above a room's composer, highest priority first. A
/// request outranks an error because it has somewhere to go; an error outranks
/// recovery because the user can read it. `ChatView` borrows `.updateSignIn` (#942).
enum BotComposerPill: Equatable {
    /// A blocking request with a card in the transcript to jump to.
    case request(String)
    /// A blocking request the phone cannot show; the line is the whole message.
    case notice(String)
    case error(String)
    case reconnect
    /// Reconnect's slot after the host refused the saved password: reconnecting
    /// would only send it again, so the button opens the sign-in form instead.
    case updateSignIn
    case retrySend

    var errorText: String? { if case .error(let text) = self { return text }; return nil }

    /// Rooms' host exposes no turn start time, so routine working/connecting states
    /// stay quiet; requests and recovery remain reachable. `needsSignIn` holds Update
    /// sign-in in place even while a background leaves the room idle, because the room
    /// never signs in again with a rejected password.
    static func room(link: BotRoomReader.Link, blocked: Bool, hasActions: Bool,
                     mayRetry: Bool, needsSignIn: Bool = false, errorText: String?) -> BotComposerPill? {
        if let errorText { return .error(errorText) }
        if needsSignIn { return .updateSignIn }
        if link == .stopped { return .reconnect }
        if mayRetry { return .retrySend }
        if link == .live && blocked {
            return hasActions ? .request(String(localized: "Waiting for your answer"))
                : .notice(String(localized: "Waiting on Hermes Desktop"))
        }
        return nil
    }
}

/// One centered capsule with material and no motion of its own. Request, Reconnect,
/// Update sign-in and Retry send are buttons; an error is tappable to dismiss.
struct BotComposerPillView: View {
    let pill: BotComposerPill
    var onReconnect: () -> Void = {}
    let onUpdateSignIn: () -> Void
    var onShowRequest: () -> Void = {}
    var onDismissError: () -> Void = {}
    var onRetrySend: () -> Void = {}

    var body: some View {
        Group {
            switch pill {
            case .request(let text):
                Button(action: onShowRequest) { Label(text, systemImage: "arrow.down.circle") }
            case .notice(let text):
                Label(text, systemImage: "exclamationmark.circle")
            case .error(let text):
                Button(action: onDismissError) { Label(text, systemImage: "exclamationmark.triangle") }
                    .accessibilityHint(Text("Dismisses this message"))
            case .reconnect:
                Button(action: onReconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
            case .updateSignIn:
                Button(action: onUpdateSignIn) { Label("Update sign-in", systemImage: "key") }
            case .retrySend:
                Button(action: onRetrySend) { Label("Retry send", systemImage: "arrow.up") }
            }
        }
        .buttonStyle(.plain)
        .font(AppFont.footnote())
        .lineLimit(3)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.appPrimary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.appMaterial(.regularMaterial), in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("bot-chat-status")
    }
}
