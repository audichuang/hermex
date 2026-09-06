import Foundation

/// Recently used workspace paths, scoped by active server and resolved Profile.
/// Paths are credential-like, so they live in Keychain rather than UserDefaults.
struct WorkspaceRecentsStore: Sendable {
    static let shared = WorkspaceRecentsStore()

    private let keychain: any KeychainStoring
    private let limit: Int

    init(
        keychain: any KeychainStoring = KeychainStore(),
        limit: Int = 5
    ) {
        self.keychain = keychain
        self.limit = limit
    }

    func recents(server: URL?, profileName: String?) -> [String] {
        guard let scope = Self.scope(server: server, profileName: profileName) else {
            return []
        }

        guard let json = try? keychain.load(.recentWorkspaces, scope: scope),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return Self.limitedDeduplicated(decoded, limit: limit)
    }

    @discardableResult
    func record(_ path: String, server: URL?, profileName: String?) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let scope = Self.scope(server: server, profileName: profileName) else {
            return recents(server: server, profileName: profileName)
        }

        let paths = Self.limitedDeduplicated([trimmed] + recents(server: server, profileName: profileName), limit: limit)
        save(paths, scope: scope)
        return paths
    }

    static func isWithinTrustedRoots(_ path: String, roots: [WorkspaceRoot]) -> Bool {
        let trusted = roots.compactMap(\.path).filter { !$0.isEmpty }
        return trusted.contains { root in
            if path == root {
                return true
            }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix)
        }
    }

    static func scope(server: URL?, profileName: String?) -> String? {
        guard let server else { return nil }
        let profile = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !profile.isEmpty else { return nil }
        return "\(server.absoluteString)::\(profile)"
    }

    private func save(_ paths: [String], scope: String) {
        let limited = Self.limitedDeduplicated(paths, limit: limit)
        guard let data = try? JSONEncoder().encode(limited),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.save(json, forKey: .recentWorkspaces, scope: scope)
    }

    private static func limitedDeduplicated(_ paths: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where !path.isEmpty && seen.insert(path).inserted {
            result.append(path)
            if result.count == limit {
                break
            }
        }
        return result
    }
}

struct ComposerWorkspacePickerRow: Equatable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String?
    let isCurrent: Bool

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        return path.lastPathComponentFallback
    }
}

struct ComposerWorkspacePickerContent: Equatable {
    var current: ComposerWorkspacePickerRow?
    var recents: [ComposerWorkspacePickerRow]
    var saved: [ComposerWorkspacePickerRow]
    var suggestions: [ComposerWorkspacePickerRow]

    var hasLocalMatches: Bool {
        current != nil || !recents.isEmpty || !saved.isEmpty
    }

    var isEmpty: Bool {
        current == nil && recents.isEmpty && saved.isEmpty && suggestions.isEmpty
    }

    static func make(
        query: String,
        currentPath: String?,
        savedRoots: [WorkspaceRoot],
        recentPaths: [String],
        suggestions: [String]
    ) -> Self {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let namesByPath = Self.namesByPath(from: savedRoots)
        var seen = Set<String>()

        func take(_ path: String?, isCurrent: Bool) -> ComposerWorkspacePickerRow? {
            guard let path, !path.isEmpty, seen.insert(path).inserted else { return nil }
            let row = ComposerWorkspacePickerRow(
                path: path,
                name: namesByPath[path],
                isCurrent: isCurrent
            )
            guard Self.matches(row, query: trimmedQuery) else { return nil }
            return row
        }

        let current = take(currentPath, isCurrent: true)

        let recents = recentPaths.compactMap { path in
            take(path, isCurrent: false)
        }

        let saved = savedRoots.compactMap { root in
            take(root.path, isCurrent: false)
        }

        let suggestionRows = suggestions.compactMap { path in
            take(path, isCurrent: false)
        }

        return Self(
            current: current,
            recents: recents,
            saved: saved,
            suggestions: suggestionRows
        )
    }

    static func matches(_ row: ComposerWorkspacePickerRow, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if row.path.localizedCaseInsensitiveContains(query) {
            return true
        }
        if let name = row.name, name.localizedCaseInsensitiveContains(query) {
            return true
        }
        return false
    }

    private static func namesByPath(from roots: [WorkspaceRoot]) -> [String: String] {
        var names: [String: String] = [:]
        for root in roots {
            guard let path = root.path, !path.isEmpty else { continue }
            if names[path] == nil, let name = root.name, !name.isEmpty {
                names[path] = name
            }
        }
        return names
    }
}
