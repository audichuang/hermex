import Foundation

enum HermesFallbackNotice {
    static func line(kind: String?, text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case "fallback": return trimmed
        case "process", "goal": return nil
        default:
            let named = trimmed.range(
                of: "model fallback|provider fallback|switched to fallback|switching to fallback",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return named ? trimmed : nil
        }
    }
}

extension ChatViewModel {
    func hermesModelDidFallBack(_ line: String) {
        guard !pinnedLocalNotices.contains(line) else { return }
        let afterLastPrompt = messages.reversed().prefix { $0.role != "user" }
        guard !afterLastPrompt.contains(where: { $0.role == "local_notice" && $0.content == line }) else { return }
        if activeStreamID == nil { appendLocalNoticeMessage(line) } else { pinLocalNoticeMessage(line) }
    }
}
