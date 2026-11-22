import SwiftUI

struct BotRoomAttachmentCard: View {
    let file: BotRoomAttachmentList.File
    let reader: BotRoomReader
    let transcriptMediaCacheNamespace: String

    @State private var observer = UUID()
    @State private var nearViewport = false
    @State private var preview = BotRoomPreviewSlot()
    @State private var showingFile = false

    private var request: BotRoomAttachment.Request? {
        reader.mayDownload ? file.request : nil
    }

    private var previewTarget: BotRoomAttachment.Request? {
        nearViewport && file.attachment.canPreview ? file.request : nil
    }

    var body: some View {
        Group {
            if request != nil {
                Button { showingFile = true } label: { card }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Download \(file.name)"))
                    .accessibilityValue(file.sizeText ?? "")
            } else {
                card
            }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
            return viewport.insetBy(dx: 0, dy: -200).intersects(CGRect(origin: .zero, size: geometry.size))
        } action: {
            nearViewport = $0
        }
        .onChange(of: previewTarget, initial: true) { _, target in preview.aim(at: target) }
        .onChange(of: preview.load(mayDownload: reader.mayDownload), initial: true) { _, request in
            reader.cancelAttachmentPreview(observer: observer)
            if let request {
                reader.previewAttachment(request, namespace: transcriptMediaCacheNamespace, observer: observer) {
                    preview.image = $0
                }
            }
        }
        .onDisappear {
            reader.cancelAttachmentPreview(observer: observer)
            preview.aim(at: nil)
            nearViewport = false
        }
        .sheet(isPresented: $showingFile) {
            if let request = file.request {
                BotArtifactPreview(reference: .init(rawReference: request.attachmentID), title: file.name) {
                    try await reader.downloadAttachment(request)
                }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = preview.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { icon; details.fixedSize(); downloadIcon }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { icon; downloadIcon }
                    details.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name).font(AppFont.subheadline())
            if let sizeText = file.sizeText { Text(sizeText).font(AppFont.caption()).foregroundStyle(.appSecondary) }
            if file.attachment.exceedsDownloadLimit {
                Text("Too large. Download in Hermes Desktop.")
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
            }
        }
    }

    private var icon: some View {
        Image(systemName: file.attachment.kind == .image ? "photo" : "doc").accessibilityHidden(true)
    }

    @ViewBuilder private var downloadIcon: some View {
        if request != nil {
            Image(systemName: "arrow.down.circle").accessibilityHidden(true)
        }
    }

}
