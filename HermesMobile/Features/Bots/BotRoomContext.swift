import Foundation

struct BotRoomContext: Equatable {
    static let maximumPurposeLength = 500
    static let maximumNotesBytes = 4096

    let purpose: String
    let notes: String
    let routing: String
    let leadMemberID: String?

    init?(_ value: BotJSON) {
        guard value.fields != nil else { return nil }
        purpose = value["purpose"].text ?? ""
        notes = value["notes"].text ?? ""
        routing = value["routing"].text ?? "everyone"
        leadMemberID = value["lead_member_id"].text.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func purposeLength(_ purpose: String) -> Int {
        purpose.unicodeScalars.split(whereSeparator: isWhitespace).map(String.init)
            .joined(separator: " ").unicodeScalars.count
    }

    static func notesBytes(_ notes: String) -> Int {
        let scalars = notes.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return 0 }
        return String(scalars[first...last]).utf8.count
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }
}
