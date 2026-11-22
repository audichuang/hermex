import Foundation

struct BotPreviewText: Equatable {
    let text: String
    let fromBot: String?

    var hasContent: Bool {
        fromBot != nil || !text.isEmpty
    }

    var displayLine: String {
        guard let fromBot else { return text }
        return text.isEmpty ? "\(fromBot): …" : "\(fromBot): \(text)"
    }

    private static let agentPrefix = try! NSRegularExpression(
        pattern: #"^Message from agent '([^']+)'(?::\s*)?"#,
        options: .caseInsensitive
    )
    private static let botPrefixWithColon = try! NSRegularExpression(
        pattern: #"^Message from 🤖\s*([^:]+):\s*"#,
        options: .caseInsensitive
    )
    private static let botPrefixTruncated = try! NSRegularExpression(
        pattern: #"^Message from 🤖\s*([^\s(@:]+)"#,
        options: .caseInsensitive
    )
    private static let handleSuffix = try! NSRegularExpression(
        pattern: #"^(.*?)\s*\(@([^\s)]+)\)$"#
    )
    private static let markdownRules: [(regex: NSRegularExpression, replacement: String)] = [
        (try! NSRegularExpression(pattern: #"```[\s\S]*?```"#), " "),
        (try! NSRegularExpression(pattern: #"`([^`\n]*)`"#), "$1"),
        (try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#), "$1"),
        (try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#), "$1"),
        (try! NSRegularExpression(pattern: #"(\*\*|__)(.*?)\1"#), "$2"),
        (try! NSRegularExpression(pattern: #"(^|\s)[*_](\S(?:.*?\S)?)[*_](?=\s|$|[.,;:!?])"#), "$1$2"),
        (try! NSRegularExpression(pattern: #"~~(.*?)~~"#), "$1"),
        (try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+"#, options: .anchorsMatchLines), ""),
        (try! NSRegularExpression(pattern: #"^\s{0,3}>\s?"#, options: .anchorsMatchLines), ""),
        (try! NSRegularExpression(pattern: #"\s+"#), " "),
    ]

    static func parse(_ preview: String?, roster: [BotProfile] = []) -> BotPreviewText {
        let trimmed = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return BotPreviewText(text: "", fromBot: nil) }

        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        if let match = agentPrefix.firstMatch(in: trimmed, range: fullRange),
           let nameRange = Range(match.range(at: 1), in: trimmed),
           let matchedRange = Range(match.range, in: trimmed) {
            let rawName = String(trimmed[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawName.isEmpty {
                let body = String(trimmed[matchedRange.upperBound...])
                let sender = resolveSender(name: rawName, handle: nil, in: roster)
                return BotPreviewText(text: stripMarkdown(body), fromBot: sender)
            }
        }

        if let match = botPrefixWithColon.firstMatch(in: trimmed, range: fullRange),
           let headerRange = Range(match.range(at: 1), in: trimmed),
           let matchedRange = Range(match.range, in: trimmed) {
            let header = String(trimmed[headerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let (rawName, handle) = parseBotHeader(header) {
                let body = String(trimmed[matchedRange.upperBound...])
                let sender = resolveSender(name: rawName, handle: handle, in: roster)
                return BotPreviewText(text: stripMarkdown(body), fromBot: sender)
            }
        } else if let match = botPrefixTruncated.firstMatch(in: trimmed, range: fullRange),
                  let nameRange = Range(match.range(at: 1), in: trimmed) {
            let rawName = String(trimmed[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawName.isEmpty {
                let sender = resolveSender(name: rawName, handle: nil, in: roster)
                return BotPreviewText(text: "", fromBot: sender)
            }
        }

        return BotPreviewText(text: stripMarkdown(trimmed), fromBot: nil)
    }

    static func stripMarkdown(_ text: String) -> String {
        var result = text
        for rule in markdownRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseBotHeader(_ header: String) -> (name: String, handle: String?)? {
        guard !header.isEmpty else { return nil }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        if let match = handleSuffix.firstMatch(in: header, range: range),
           let nameRange = Range(match.range(at: 1), in: header),
           let handleRange = Range(match.range(at: 2), in: header) {
            let display = String(header[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = String(header[handleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !display.isEmpty { return (display, handle.isEmpty ? nil : handle) }
            if !handle.isEmpty { return (handle, handle) }
            return nil
        }
        return (header, nil)
    }

    private static func resolveSender(name: String, handle: String?, in roster: [BotProfile]) -> String {
        if let handle, let match = findProfile(matching: handle, in: roster) {
            return match.name
        }
        if let match = findProfile(matching: name, in: roster) {
            return match.name
        }
        if name.lowercased() == "default" {
            return "Hermes"
        }
        return name
    }

    private static func findProfile(matching identifier: String, in roster: [BotProfile]) -> BotProfile? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = roster.first(where: { $0.id.lowercased() == key }) {
            return exact
        }
        if key == "hermes" {
            return roster.first(where: { $0.id.lowercased() == "default" })
        }
        return nil
    }
}
