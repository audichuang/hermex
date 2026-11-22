import SwiftUI

@MainActor struct BotRoomProfileView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var reader: BotRoomReader
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    var hostProfile: String? = nil
    var onUpdateSignIn: () -> Void = {}
    @State private var name = ""
    @State private var settings: BotRoomSettingsDraft?
    @State private var copiedDeliveryTarget = false
    @State private var confirmingDisband = false
    @State private var visible = false
    @State private var owner = UUID()
    @State private var revision = UUID()
    @FocusState private var editingName: Bool

    var body: some View {
        AppList {
            Section {
                VStack(spacing: 24) {
                    BotRoomAvatars(room: reader.room, roster: roster, avatars: avatars, size: 84)
                    if reader.showsRename {
                        TextField("Group name", text: $name)
                            .font(AppFont.title2().bold()).multilineTextAlignment(.center)
                            .focused($editingName).submitLabel(.done)
                            .disabled(!reader.mayRename)
                            .onSubmit { commitName() }
                        if name != reader.room.name {
                            Button("Save name") { commitName() }
                                .disabled(!reader.mayRename || !BotRoomRPC.validName(name))
                        }
                        if !BotRoomRPC.validName(name) {
                            Text("Enter a name of up to 200 characters.").font(AppFont.caption())
                        }
                    } else { Text(reader.room.name).font(AppFont.title2().bold()) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            if let context = reader.context, !context.purpose.isEmpty || reader.showsSettings {
                Section {
                    if !context.purpose.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Purpose").font(AppFont.caption()).foregroundStyle(.secondary)
                            Text(context.purpose)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if reader.showsSettings {
                        Button("Room settings") { settings = BotRoomSettingsDraft(context: context) }
                    }
                }
            }
            Section {
                ForEach(reader.room.members) { member in
                    if let profile = roster.first(where: { $0.id == member.profile }) {
                        NavigationLink {
                            BotProfileEditorView(server: reader.key.server, connection: reader.connection,
                                                 profile: profile, avatar: avatars[profile.id])
                        } label: { memberRow(member) }
                    } else { memberRow(member) }
                }
            } appFooter: {
                Text("Members are set when the group is created.")
            }
            deliveryTargetSection
            if reader.foreignAuthority { Text("Managed by another Hermes").font(AppFont.callout()) }
            if let message = reader.commandMessage { Text(message).font(AppFont.callout()) }
            if reader.finishingStop { Text("Finishing stop…").font(AppFont.callout()) }
            if reader.link == .stopped {
                if let error = reader.errorMessage { Text(error).font(AppFont.callout()) }
                if reader.needsSignIn {
                    Button("Update sign-in", action: onUpdateSignIn)
                } else {
                    Button("Reconnect") { revision = UUID() }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $settings) { draft in
            BotRoomSettingsView(reader: reader, draft: draft)
        }
        .toolbar {
            if reader.showsDisband {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Disband Group", role: .destructive) { confirmingDisband = true }
                            .disabled(!reader.mayDisband)
                        if reader.finishingStop { Text("Finishing stop…") }
                    } label: { Label("Group options", systemImage: "ellipsis") }
                }
            }
        }
        .confirmationDialog("Disband this group?", isPresented: $confirmingDisband, titleVisibility: .visible) {
            Button("Disband Group", role: .destructive) { Task { await reader.disband() } }
                .disabled(!reader.mayDisband)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The room and its history will be removed from every device. All bots in it will stop. The room cannot be restored.")
        }
        .task(id: revision) {
            visible = true; name = reader.room.name
            if scenePhase == .active { await reader.open(owner: owner) }
        }
        .onChange(of: reader.room.name) { if !editingName { name = reader.room.name } }
        .onChange(of: scenePhase) {
            guard visible else { return }
            switch scenePhase {
            case .background: reader.leave(owner: owner)
            case .active where reader.link == .idle: revision = UUID()
            default: break
            }
        }
        .onDisappear { visible = false; reader.leave(owner: owner) }
        .onChange(of: NetworkPathMonitor.shared.changeCount) { if visible { reader.networkPathDidChange() } }
        .onChange(of: hostProfile) { copiedDeliveryTarget = false }
        .task(id: copiedDeliveryTarget) {
            guard copiedDeliveryTarget else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedDeliveryTarget = false
        }
    }
    private var deliveryTargetSection: some View {
        let target = BotRoomDeliveryTarget.address(roomID: reader.room.id, profile: hostProfile)
        return Section {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    deliveryTargetText(target)
                    Spacer(minLength: 8)
                    copyDeliveryTargetButton(target)
                }
                VStack(alignment: .leading, spacing: 8) {
                    deliveryTargetText(target)
                    copyDeliveryTargetButton(target)
                }
            }
        } header: {
            Text("Delivery target")
        } appFooter: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use this target in a scheduled task’s deliver field to post here.")
                if BotRoomDeliveryTarget.normalizedProfile(hostProfile) == nil {
                    Text("If the scheduled task belongs to another Profile, append @profile.")
                }
            }
        }
    }
    private func deliveryTargetText(_ target: String) -> some View {
        Text(verbatim: target)
            .font(AppFont.footnote().monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func copyDeliveryTargetButton(_ target: String) -> some View {
        Button {
            UIPasteboard.general.string = target
            copiedDeliveryTarget = true
        } label: {
            Label(copiedDeliveryTarget ? String(localized: "Copied") : String(localized: "Copy"),
                  systemImage: copiedDeliveryTarget ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(copiedDeliveryTarget ? String(localized: "Copied delivery target") : String(localized: "Copy delivery target"))
    }
    private func commitName() {
        guard reader.mayRename, BotRoomRPC.validName(name) else { return }
        editingName = false
        let submitted = name
        Task { await reader.rename(submitted) }
    }
    private func memberRow(_ member: BotGroupRoom.Member) -> some View {
        let activity = BotRoomMemberOutcome.activeActivity(for: member.id, in: reader.status.activity)
        let status = BotRoomMemberOutcome.statusText(activity: activity, outcome: reader.memberOutcomes[member.id])
        let handle = member.handle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 14) {
            BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                if let handle, !handle.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(member.name)
                            Text(verbatim: "@\(handle)").font(AppFont.caption()).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                            Text(verbatim: "@\(handle)").font(AppFont.caption()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(member.name)
                }
                if reader.context?.routing == "lead", reader.context?.leadMemberID == member.id {
                    Text("Room lead").font(AppFont.caption()).foregroundStyle(.secondary)
                }
                if let status {
                    Text(status).font(AppFont.caption()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
