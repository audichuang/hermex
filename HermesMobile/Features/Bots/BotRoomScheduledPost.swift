import SwiftUI

extension BotRoomEvent {
    var isScheduledPost: Bool {
        guard kind == "message.user", let id = actor["id"].text else { return false }
        return id.hasPrefix("cron:") || id.hasPrefix("cron-notice:")
    }

    func isScheduledPostRoot(for threadID: String) -> Bool {
        guard isScheduledPost,
              threadID.hasPrefix("cron-"),
              let eventID,
              eventID.hasPrefix("cron-post:") else {
            return false
        }
        let digest = threadID.dropFirst("cron-".count)
        guard !digest.isEmpty else { return false }
        return eventID.dropFirst("cron-post:".count).hasPrefix(digest)
    }

    func authorName(in room: BotGroupRoom) -> String {
        if isScheduledPost {
            if let displayName = actor["display_name"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                return displayName
            }
            if let id = actor["id"].text {
                let raw: Substring
                if id.hasPrefix("cron-notice:") {
                    raw = id.dropFirst("cron-notice:".count)
                } else if id.hasPrefix("cron:") {
                    raw = id.dropFirst("cron:".count)
                } else {
                    raw = id[...]
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return String(localized: "Scheduled")
        }
        if kind == "message.user" {
            return String(localized: "You")
        }
        return sender(in: room)
    }
}

enum BotRoomDeliveryTarget {
    static func normalizedProfile(_ profile: String?) -> String? {
        guard let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func address(roomID: String, profile: String?) -> String {
        guard let profile = normalizedProfile(profile) else {
            return "room:\(roomID)"
        }
        return "room:\(roomID)@\(profile)"
    }
}

struct BotRoomScheduledPostAvatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "clock")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.appSecondary)
            .frame(width: size, height: size)
            .background(.fill.tertiary, in: Circle())
            .accessibilityHidden(true)
    }
}

struct BotRoomScheduledPostHeader: View {
    let name: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                authorText
                badge
            }
            VStack(alignment: .leading, spacing: 4) {
                authorText
                badge
            }
        }
    }

    private var authorText: some View {
        Text(verbatim: name)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
    }

    private var badge: some View {
        Text("Scheduled")
            .font(AppFont.caption2(weight: .medium))
            .foregroundStyle(.appSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
    }
}
