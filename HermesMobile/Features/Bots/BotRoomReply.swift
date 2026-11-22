import SwiftUI

struct BotRoomReplyTarget: Equatable {
    let name: String
    let handle: String?
    let excerpt: String

    init(name: String, handle: String?, excerpt: String) {
        self.name = name
        self.handle = handle
        self.excerpt = excerpt
    }

    init(event: BotRoomEvent, in room: BotGroupRoom) {
        name = event.sender(in: room)
        handle = event.member(in: room)?.handle
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        excerpt = Self.excerpt(from: event)
    }

    static func addressing(_ draft: String, to handle: String) -> String {
        let clean = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return draft }
        let trimmed = draft.drop(while: \.isWhitespace)
        if trimmed.first == "@" {
            let token = trimmed.dropFirst().prefix(while: isHandleCharacter)
            if token.caseInsensitiveCompare(clean) == .orderedSame {
                return draft
            }
        }
        return "@\(clean) \(draft)"
    }

    private static func excerpt(from event: BotRoomEvent) -> String {
        let text = event.payload["text"].text ?? ""
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func isHandleCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        let value = scalar.value
        return (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
            || value == 0x2E || value == 0x5F || value == 0x3A || value == 0x2D
    }
}

struct BotRoomReplyChip: View {
    let target: BotRoomReplyTarget
    let onCancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(target.name)")
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if !target.excerpt.isEmpty {
                    Text(target.excerpt)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(AppFont.caption(weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.appSecondary)
            .accessibilityLabel(Text("Cancel reply"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
