import SwiftUI
import UIKit

@MainActor
enum BotMessageActions {
    static func items(
        copyText: String?,
        isHapticsEnabled: Bool,
        reply: (() -> Void)? = nil,
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
    ) -> [ChatMessageActionItem] {
        var result: [ChatMessageActionItem] = []
        if let reply {
            result.append(ChatMessageActionItem(
                kind: .reply,
                title: String(localized: "Reply"),
                systemImage: "arrowshape.turn.up.left",
                isEnabled: true,
                perform: reply
            ))
        }
        if let copyText, !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(ChatMessageActionItem(
                kind: .copy,
                title: String(localized: "Copy"),
                systemImage: "doc.on.doc",
                isEnabled: true,
                perform: {
                    copy(copyText)
                    ChatHaptics.copied(isEnabled: isHapticsEnabled)
                }
            ))
        }
        return result
    }
}
