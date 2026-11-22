import Foundation
import UIKit

struct BotRoomAttachment: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case image, pdf, file }

    static let maximumDownloadBytes = 12_000_000
    static let maximumPreviewBytes = 5 * 1024 * 1024
    static let downloadMethod = "groups.attachment.download"

    let attachmentID: String?
    let kind: Kind
    let name: String?
    let mime: String?
    let size: Int?

    init?(_ value: BotJSON) {
        guard value.fields != nil else { return nil }
        attachmentID = value["attachment_id"].text
        kind = value["kind"].text.flatMap(Kind.init(rawValue:)) ?? .file
        name = value["name"].text
        mime = value["mime"].text
        size = value["size"].integer.flatMap { $0 >= 0 ? $0 : nil }
    }

    var displayName: String {
        guard let name, !name.isEmpty else { return String(localized: "File") }
        return name
    }

    var exceedsDownloadLimit: Bool { size.map { $0 > Self.maximumDownloadBytes } ?? false }
    var canPreview: Bool { kind == .image && (size.map { $0 <= Self.maximumPreviewBytes } ?? false) }

    var json: BotJSON {
        var fields: [String: BotJSON] = ["kind": .string(kind.rawValue)]
        fields["attachment_id"] = attachmentID.map(BotJSON.string)
        fields["name"] = name.map(BotJSON.string)
        fields["mime"] = mime.map(BotJSON.string)
        fields["size"] = size.map { .number(Double($0)) }
        return .object(fields)
    }

    struct Request: Hashable {
        let eventID: String
        let attachmentID: String

        init?(eventID: String?, attachment: BotRoomAttachment) {
            guard !attachment.exceedsDownloadLimit, let eventID, let attachmentID = attachment.attachmentID,
                  BotRoomRPC.validID(eventID), BotRoomRPC.validID(attachmentID) else { return nil }
            self.eventID = eventID
            self.attachmentID = attachmentID
        }
    }
}

extension BotRoomEvent {
    var roomAttachments: [BotRoomAttachment] {
        guard isMessage else { return [] }
        return (payload["attachments"].list ?? []).compactMap(BotRoomAttachment.init)
    }
}

struct BotRoomAttachmentList: Equatable {
    struct File: Equatable {
        let attachment: BotRoomAttachment
        let request: BotRoomAttachment.Request?
        let name: String
        let sizeText: String?

        init(_ attachment: BotRoomAttachment, eventID: String?) {
            self.attachment = attachment
            request = .init(eventID: eventID, attachment: attachment)
            name = attachment.displayName
            sizeText = attachment.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        }
    }

    let files: [File]
    let summary: String

    init?(_ event: BotRoomEvent) {
        let files = event.roomAttachments.map { File($0, eventID: event.eventID) }
        guard let first = files.first else { return nil }
        self.files = files
        let name = first.name
        summary = files.count == 1 ? name : String(localized: "\(name) · Files: \(files.count)")
    }
}

/// One card's preview picture. The picture follows what the card wants to show, not whether the room is
/// live, so a reconnect keeps it on screen instead of collapsing the row and loading it again.
struct BotRoomPreviewSlot {
    var image: UIImage?
    private var target: BotRoomAttachment.Request?

    mutating func aim(at target: BotRoomAttachment.Request?) {
        guard target != self.target else { return }
        self.target = target
        image = nil
    }

    func load(mayDownload: Bool) -> BotRoomAttachment.Request? {
        image == nil && mayDownload ? target : nil
    }
}

@MainActor final class BotRoomPreviewQueue {
    struct Key: Hashable {
        let wire: ObjectIdentifier
        let request: BotRoomAttachment.Request
    }

    typealias Load = @MainActor () async throws -> Data
    typealias Deliver = @MainActor (UIImage?) -> Void

    private struct Preview {
        let key: Key
        let cacheKey: String
        let load: Load
        var observers: [UUID: Deliver]
    }

    private var waiting: [Preview] = []
    private var active: [Key: [UUID: Deliver]] = [:]
    private var downloads: [Key: Task<Data, Error>] = [:]
    private var automaticCount = 0

    func enqueue(key: Key, cacheKey: String, observer: UUID, load: @escaping Load, deliver: @escaping Deliver) {
        if active[key] != nil {
            active[key]?[observer] = deliver
        } else if let index = waiting.firstIndex(where: { $0.key == key }) {
            waiting[index].observers[observer] = deliver
        } else {
            let preview = Preview(key: key, cacheKey: cacheKey, load: load, observers: [observer: deliver])
            if let download = downloads[key] {
                start(preview, sharing: download)
            } else {
                waiting.append(preview)
                advance()
            }
        }
    }

    func cancel(observer: UUID) {
        for index in waiting.indices { waiting[index].observers[observer] = nil }
        waiting.removeAll { $0.observers.isEmpty }
        for key in Array(active.keys) { active[key]?[observer] = nil }
    }

    func suspend() {
        waiting.removeAll()
        for key in Array(active.keys) { active[key] = [:] }
    }

    func download(_ key: Key, load: @escaping Load) async throws -> Data {
        let task = sharedDownload(key, load: load)
        if let index = waiting.firstIndex(where: { $0.key == key }) {
            start(waiting.remove(at: index), sharing: task)
        }
        return try await task.value
    }

    private func sharedDownload(_ key: Key, load: @escaping Load) -> Task<Data, Error> {
        if let task = downloads[key] { return task }
        let task = Task {
            defer { downloads[key] = nil }
            return try await load()
        }
        downloads[key] = task
        return task
    }

    private func advance() {
        while automaticCount < 2 && !waiting.isEmpty {
            start(waiting.removeFirst())
        }
    }

    private func start(_ preview: Preview, sharing download: Task<Data, Error>? = nil) {
        let key = preview.key, cacheKey = preview.cacheKey, load = preview.load
        let usesSlot = download == nil
        if usesSlot { automaticCount += 1 }
        active[key] = preview.observers
        Task {
            let image = await TranscriptImageCache.shared.image(forKey: cacheKey) {
                if let download { return try? await download.value }
                return try? await self.sharedDownload(key, load: load).value
            }
            let observers = active.removeValue(forKey: key) ?? [:]
            if usesSlot { automaticCount -= 1 }
            for deliver in observers.values { deliver(image) }
            advance()
        }
    }
}
