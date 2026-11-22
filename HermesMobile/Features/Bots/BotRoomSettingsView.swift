import SwiftUI

@MainActor @Observable final class BotRoomSettingsDraft: Identifiable {
    enum Routing: Hashable {
        case everyone, auto, lead(String), unchanged
    }

    var purpose: String
    var notes: String
    var routing: Routing
    private(set) var saving = false
    private(set) var error: String?
    @ObservationIgnored private var initialPurpose: String
    @ObservationIgnored private var initialNotes: String
    @ObservationIgnored private var initialRouting: Routing

    init(context: BotRoomContext) {
        let initialRouting: Routing = switch context.routing {
        case "everyone": .everyone
        case "auto": .auto
        case "lead": context.leadMemberID.map(Routing.lead) ?? .unchanged
        default: .unchanged
        }
        purpose = context.purpose
        notes = context.notes
        routing = initialRouting
        initialPurpose = context.purpose
        initialNotes = context.notes
        self.initialRouting = initialRouting
    }

    var purposeLength: Int { BotRoomContext.purposeLength(purpose) }
    var notesBytes: Int { BotRoomContext.notesBytes(notes) }
    var purposeOverLimit: Bool { purposeLength > BotRoomContext.maximumPurposeLength }
    var notesOverLimit: Bool { notesBytes > BotRoomContext.maximumNotesBytes }

    func maySave(in reader: BotRoomReader) -> Bool {
        !saving && reader.maySaveContext && !purposeOverLimit && !notesOverLimit
    }

    func offersAuto(in reader: BotRoomReader) -> Bool {
        routing == .auto || reader.context?.routing == "auto" || reader.status.routingModes.contains("auto")
    }

    func save(in reader: BotRoomReader) async -> Bool {
        guard maySave(in: reader) else { return false }
        let savedPurpose = purpose != initialPurpose ? purpose : reader.context?.purpose ?? purpose
        let savedNotes = notes != initialNotes ? notes : reader.context?.notes ?? notes
        let savedRouting = routing == initialRouting ? Routing.unchanged : routing
        let request: HermesCall.RoomContext = switch savedRouting {
        case .everyone: .init(purpose: savedPurpose, notes: savedNotes, routing: "everyone", leadMemberID: "")
        case .auto: .init(purpose: savedPurpose, notes: savedNotes, routing: "auto", leadMemberID: "")
        case .lead(let id): .init(purpose: savedPurpose, notes: savedNotes, routing: "lead", leadMemberID: id)
        case .unchanged: .init(purpose: savedPurpose, notes: savedNotes, routing: nil, leadMemberID: nil)
        }
        saving = true
        error = nil
        defer { saving = false }
        guard await reader.saveContext(request) else {
            error = reader.commandMessage ?? reader.errorMessage ?? String(localized: "Couldn’t save room settings.")
            return false
        }
        initialPurpose = purpose
        initialNotes = notes
        initialRouting = routing
        return true
    }
}

@MainActor struct BotRoomSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var notesEditorHeight = 112.0
    let reader: BotRoomReader
    @Bindable var draft: BotRoomSettingsDraft

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    TextField("Purpose", text: $draft.purpose, axis: .vertical)
                        .lineLimit(1...3)
                    if draft.purposeOverLimit {
                        limitMessage("Purpose exceeds the limit.", used: draft.purposeLength,
                                     limit: BotRoomContext.maximumPurposeLength)
                    }
                } header: { Text("Purpose") }
                Section {
                    TextEditor(text: $draft.notes)
                        .frame(height: notesEditorHeight)
                        .accessibilityLabel("Shared notes")
                } header: {
                    Text("Shared notes")
                } appFooter: {
                    if draft.notesOverLimit {
                        limitMessage("Shared notes exceed the byte limit.", used: draft.notesBytes,
                                     limit: BotRoomContext.maximumNotesBytes)
                    } else {
                        Text("\(draft.notesBytes) / \(BotRoomContext.maximumNotesBytes)").monospacedDigit()
                    }
                }
                Section {
                    Menu {
                        Picker("Who answers without a mention", selection: $draft.routing) {
                            if draft.routing == .unchanged {
                                Text("Current setting").tag(BotRoomSettingsDraft.Routing.unchanged)
                            }
                            Text("Everyone").tag(BotRoomSettingsDraft.Routing.everyone)
                            if draft.offersAuto(in: reader) {
                                Text("Pick automatically").tag(BotRoomSettingsDraft.Routing.auto)
                            }
                            ForEach(reader.room.members) { member in
                                Text("\(member.name) as lead").tag(BotRoomSettingsDraft.Routing.lead(member.id))
                            }
                        }
                    } label: {
                        HStack {
                            routingSelection.multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down").font(AppFont.caption()).accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Who answers without a mention")
                    .accessibilityValue(routingSelection)
                } header: {
                    Text("Who answers without a mention")
                } appFooter: { routingHint }
                if let error = draft.error {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
            .disabled(draft.saving)
            .navigationTitle("Room settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(draft.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { if await draft.save(in: reader) { dismiss() } }
                    } label: {
                        if draft.saving { ProgressView().accessibilityLabel("Saving…") }
                        else { Text("Save") }
                    }
                    .disabled(!draft.maySave(in: reader))
                }
            }
        }
        .interactiveDismissDisabled(draft.saving)
        .adaptiveFormPresentation()
        .onChange(of: draft.purposeOverLimit) {
            if draft.purposeOverLimit { AccessibilityNotification.Announcement(String(localized: "Purpose exceeds the limit.")).post() }
        }
        .onChange(of: draft.notesOverLimit) {
            if draft.notesOverLimit { AccessibilityNotification.Announcement(String(localized: "Shared notes exceed the byte limit.")).post() }
        }
        .onChange(of: draft.error) {
            if let error = draft.error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    private var routingSelection: Text {
        switch draft.routing {
        case .everyone: Text("Everyone")
        case .auto: Text("Pick automatically")
        case .lead(let id):
            Text("\(reader.room.members.first(where: { $0.id == id })?.name ?? id) as lead")
        case .unchanged: Text("Current setting")
        }
    }

    @ViewBuilder private var routingHint: some View {
        switch draft.routing {
        case .everyone: Text("Every member gets a turn.")
        case .auto: Text("Hermes picks who answers. Mentions go straight to the named members.")
        case .lead: Text("The lead picks who answers. Mentions go straight to the named members.")
        case .unchanged: EmptyView()
        }
    }

    private func limitMessage(_ message: LocalizedStringKey, used: Int, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
            Text("\(used) / \(limit)").monospacedDigit()
        }
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
    }
}
