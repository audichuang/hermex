import CryptoKit
import Foundation
import OSLog

@MainActor final class BotRoomDraftStore {
    struct Draft: Codable {
        var texts: [String: String]
        var pending: [BotRoomReader.Send]

        private enum CodingKeys: String, CodingKey { case texts, pending }

        init(texts: [String: String] = [:], pending: [BotRoomReader.Send] = []) {
            self.texts = texts
            self.pending = pending
        }

        init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            texts = try record.decode([String: String].self, forKey: .texts)
            do {
                pending = try record.decodeIfPresent([BotRoomReader.Send].self, forKey: .pending) ?? []
            } catch DecodingError.typeMismatch {
                pending = [try record.decode(BotRoomReader.Send.self, forKey: .pending)]
            }
        }
    }

    static let shared = BotRoomDraftStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BotRoomDrafts", isDirectory: true))

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "BotRoomDraftStore")
    private let directory: URL
    private var generations: [BotRoomKey: UUID] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func load(_ key: BotRoomKey) -> (draft: Draft, generation: UUID) {
        let generation = generations[key] ?? UUID()
        generations[key] = generation
        do {
            let data = try Data(contentsOf: file(for: key))
            return (try JSONDecoder().decode(Draft.self, from: data), generation)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (Draft(), generation)
        } catch {
            Self.logger.error("Could not read room draft: \(error.localizedDescription, privacy: .private)")
            return (Draft(), generation)
        }
    }

    func save(_ draft: Draft, for key: BotRoomKey, generation: UUID) throws {
        guard generations[key] == generation else { throw BotFailure.stale }
        let file = file(for: key)
        if draft.texts.isEmpty && draft.pending.isEmpty {
            try delete(file)
            return
        }
        let data = try JSONEncoder().encode(draft)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeRoom(_ key: BotRoomKey) {
        generations[key] = nil
        discard(file(for: key))
    }

    func retainRooms(_ ids: Set<String>, server: URL, connectionID: UUID) {
        generations = generations.filter { key, _ in
            key.server != server || key.connectionID != connectionID || ids.contains(key.roomID)
        }
        let folder = folder(for: server, connectionID: connectionID)
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let retained = Set(ids.map(Self.filename(for:)))
            for file in files where file.pathExtension == "json" && !retained.contains(file.lastPathComponent) {
                discard(file)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            Self.logger.error("Could not list room drafts: \(error.localizedDescription, privacy: .private)")
        }
    }

    func remove(server: URL, connectionID: UUID? = nil) {
        generations = generations.filter { key, _ in
            key.server != server || (connectionID != nil && key.connectionID != connectionID)
        }
        discard(folder(for: server, connectionID: connectionID))
    }

    private func discard(_ url: URL) {
        do { try delete(url) }
        catch { Self.logger.error("Could not delete room drafts: \(error.localizedDescription, privacy: .private)") }
    }

    private func delete(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    private func file(for key: BotRoomKey) -> URL {
        folder(for: key.server, connectionID: key.connectionID).appendingPathComponent(Self.filename(for: key.roomID))
    }

    private func folder(for server: URL, connectionID: UUID?) -> URL {
        let serverDirectory = directory.appendingPathComponent(Self.digest(server.absoluteString), isDirectory: true)
        return connectionID.map { serverDirectory.appendingPathComponent($0.uuidString, isDirectory: true) }
            ?? serverDirectory
    }

    private static func filename(for roomID: String) -> String { digest(roomID) + ".json" }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
