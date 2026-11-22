import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

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

struct BotRoomUpload: Equatable, Sendable {
    let data: Data
    let name: String
    let kind: BotRoomAttachment.Kind
    let mime: String
}

enum BotRoomFiles {
    static let uploadMethod = "groups.attachment.upload"
    static let maximumCount = 8
    static let maximumFileBytes = 15_000_000
    static let maximumMessageBytes = 25_000_000
    static let draftLifetime: TimeInterval = 55 * 60

    enum Failure: LocalizedError {
        case count, fileSize, totalSize, unreadable

        var errorDescription: String? {
            switch self {
            case .count: return String(localized: "A room message can have up to 8 attachments.")
            case .fileSize: return String(localized: "Each room attachment must be 15 MB or smaller.")
            case .totalSize: return String(localized: "Room attachments must total 25 MB or less.")
            case .unreadable: return String(localized: "One of the files couldn’t be read.")
            }
        }
    }

    struct Input {
        let name: String
        let load: @MainActor () async throws -> HermexPickedMedia

        init(name: String, load: @escaping @MainActor () async throws -> HermexPickedMedia) {
            self.name = name
            self.load = load
        }

        init(_ media: HermexPickedMedia) {
            self.init(name: media.filename) { media }
        }
    }

    static func prepare(_ media: HermexPickedMedia) throws -> BotRoomUpload {
        let name = media.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name), !media.data.isEmpty else { throw Failure.unreadable }
        guard media.data.count <= maximumFileBytes else { throw Failure.fileSize }

        let data = media.data
        let prefix = Array(data.prefix(12))
        if let mime = supportedImage(prefix) {
            return BotRoomUpload(data: data, name: name, kind: .image, mime: mime)
        }
        if prefix.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) {
            return BotRoomUpload(data: data, name: name, kind: .pdf, mime: "application/pdf")
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true {
            let converted = try jpeg(from: source)
            guard converted.count <= maximumFileBytes else { throw Failure.fileSize }
            let base = (name as NSString).deletingPathExtension
            let jpegName = String(String.UnicodeScalarView(base.unicodeScalars.prefix(251))) + ".jpg"
            return BotRoomUpload(data: converted, name: jpegName, kind: .image, mime: "image/jpeg")
        }
        let mime: String
        if prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) { mime = "application/zip" }
        else if prefix.starts(with: [0x1F, 0x8B]) { mime = "application/gzip" }
        else if !data.contains(0), String(data: data, encoding: .utf8) != nil { mime = "text/plain" }
        else { mime = "application/octet-stream" }
        return BotRoomUpload(data: data, name: name, kind: .file, mime: mime)
    }

    static func admits(_ file: BotRoomUpload) -> Bool {
        (1...maximumFileBytes).contains(file.data.count) && validName(file.name)
    }

    static func admits(_ manifest: [BotRoomAttachment]) -> Bool {
        guard manifest.count <= maximumCount else { return false }
        var total = 0
        for item in manifest {
            guard let id = item.attachmentID, BotRoomRPC.validID(id),
                  let name = item.name, validName(name), let mime = item.mime, !mime.isEmpty,
                  let size = item.size, (1...maximumFileBytes).contains(size) else { return false }
            total += size
        }
        return total <= maximumMessageBytes
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.count <= 255 && name != "." && name != ".."
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0\n\r")) == nil
    }

    private static func supportedImage(_ prefix: [UInt8]) -> String? {
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: "GIF87a".utf8) || prefix.starts(with: "GIF89a".utf8) { return "image/gif" }
        if prefix.starts(with: "BM".utf8) { return "image/bmp" }
        if prefix.count == 12, prefix.starts(with: "RIFF".utf8), prefix.suffix(4).elementsEqual("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    private static func jpeg(from source: CGImageSource) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3_072
        ]
        let data = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return data as Data
    }
}
