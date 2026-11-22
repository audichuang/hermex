import SwiftUI
import UniformTypeIdentifiers

struct BotRoomAttachmentChip: Identifiable, Equatable {
    enum State: Equatable {
        case preparing
        case uploading(BotRoomUpload)
        case uploaded(BotRoomAttachment, expiresAt: Date)
        case failed(BotRoomUpload, String)
        case expired

        var byteCount: Int {
            switch self {
            case .uploading(let file), .failed(let file, _): return file.data.count
            case .uploaded(let item, _): return item.size ?? 0
            case .preparing, .expired: return 0
            }
        }

        var expiry: Date? {
            if case .uploaded(_, let expiry) = self { return expiry }
            return nil
        }
    }

    let id: UUID
    var name: String
    var state: State
}

struct BotRoomAttachmentComposer: View {
    let reader: BotRoomReader
    let threadID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let chips = reader.attachmentChips(in: threadID)
        let expiry = chips.compactMap(\.state.expiry).min()
        VStack(alignment: .leading, spacing: 4) {
            if !chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(chips) { chip in
                            attachmentChip(chip)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = reader.attachmentNotice(in: threadID) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice).font(AppFont.caption())
                    Spacer()
                    Button {
                        reader.setAttachmentNotice(nil, in: threadID)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .task(id: expiry) {
            guard let expiry else { return }
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
            reader.expireAttachments(in: threadID)
        }
    }

    private func attachmentChip(_ chip: BotRoomAttachmentChip) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chip.name).font(AppFont.caption())
                Group {
                    switch chip.state {
                    case .preparing, .uploading:
                        Text("Uploading…")
                    case .uploaded:
                        Text("Uploaded")
                    case .failed(_, let message):
                        Text(message)
                        Button("Retry upload") { Task { await reader.retryAttachment(chip.id, in: threadID) } }
                            .disabled(!reader.mayAddAttachments(in: threadID))
                    case .expired:
                        Text("Attachment expired. Add it again.")
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(Color(.appTextSecondary))
            }
            .fixedSize(horizontal: false, vertical: true)
            Button {
                reader.removeAttachment(chip.id, in: threadID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(Text("Remove attachment \(chip.name)"))
            .disabled(!reader.mayEditDraft(in: threadID))
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 300 : 230, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}

struct BotRoomAttachmentPicker: ViewModifier {
    let reader: BotRoomReader
    let threadID: String?
    @Binding var isPresented: Bool
    @State private var chooseFiles = false
    @State private var showFiles = false

    func body(content: Content) -> some View {
        content
            .background {
                HermexKeyboardRetainingOverlay(isPresented: isPresented) {
                    HermexAttachmentPickerView(
                        imageCapacity: BotRoomFiles.maximumCount - reader.attachmentChips(in: threadID).count,
                        onChooseFiles: { chooseFiles = true },
                        prepareOriginalPhoto: { media in
                            guard media.data.count <= BotRoomFiles.maximumFileBytes else { throw BotRoomFiles.Failure.fileSize }
                            return media
                        },
                        onAdd: { add($0.map(BotRoomFiles.Input.init)) },
                        onDismiss: { isPresented = false }
                    )
                }
                .frame(width: 0, height: 0)
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented, chooseFiles else { return }
                chooseFiles = false
                Task { @MainActor in
                    await Task.yield()
                    showFiles = true
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): add(urls.map(Self.file))
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        reader.setAttachmentNotice(error.localizedDescription, in: threadID)
                    }
                }
            }
    }

    private func add(_ inputs: [BotRoomFiles.Input]) {
        Task { await reader.addAttachments(inputs, in: threadID) }
    }

    static func file(_ url: URL) -> BotRoomFiles.Input {
        .init(name: url.lastPathComponent) { try await readFile(url) }
    }

    static func fileProvider(_ provider: NSItemProvider) -> BotRoomFiles.Input {
        .init(name: provider.suggestedName ?? String(localized: "File")) {
            let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        ?? (item as? String).flatMap { URL(string: $0) }
                    if let url, url.isFileURL { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? BotRoomFiles.Failure.unreadable) }
                }
            }
            return try await readFile(url)
        }
    }

    static func imageProvider(_ provider: NSItemProvider) -> BotRoomFiles.Input {
        let type = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: .image) } ?? .image
        let name = provider.suggestedName ?? imageName(extension: type.preferredFilenameExtension)
        return .init(name: name) {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let data { continuation.resume(returning: HermexPickedMedia(data: data, filename: name)) }
                    else { continuation.resume(throwing: error ?? BotRoomFiles.Failure.unreadable) }
                }
            }
        }
    }

    static func image(_ image: UIImage) -> BotRoomFiles.Input {
        let name = imageName(extension: "jpg")
        return .init(name: name) {
            let data = await Task.detached(priority: .userInitiated) { image.jpegData(compressionQuality: 0.92) }.value
            guard let data else { throw BotRoomFiles.Failure.unreadable }
            return HermexPickedMedia(data: data, filename: name)
        }
    }

    private static func imageName(extension ext: String?) -> String {
        let image = String(localized: "Image")
        return ext.map { image + "." + $0 } ?? image
    }

    private nonisolated static func readFile(_ url: URL) async throws -> HermexPickedMedia {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let size, size > BotRoomFiles.maximumFileBytes { throw BotRoomFiles.Failure.fileSize }
            return HermexPickedMedia(data: try Data(contentsOf: url), filename: url.lastPathComponent)
        }.value
    }
}
