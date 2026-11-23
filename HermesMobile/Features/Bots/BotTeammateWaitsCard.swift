import SwiftUI

struct BotTeammateWaitsCard: View {
    let waits: BotTeammateWaits
    let server: URL
    let connectionID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting on teammates")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(waits.visibleRows) { row in
                BotTeammateWaitRow(row: row, age: waits.age(of: row),
                                   open: { open(row) }, dismiss: { waits.dismiss(row.id) })
            }
            if waits.isStale {
                Text("Couldn’t refresh — showing the last known state.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if waits.showsNeverResent {
                Text("Nothing here is ever resent. An unknown outcome means the teammate may already have acted — open its chat before asking again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(waits.isStale ? 0.6 : 1)
    }

    private func open(_ row: BotTeammateDelivery) {
        let destination = BotDestination(server: server, connectionID: connectionID, profile: row.target)
        guard let url = HermesDeepLink.botURL(for: destination) else { return }
        AppIntentRouter.shared.requestDeepLink(url)
    }
}

private struct BotTeammateWaitRow: View {
    let row: BotTeammateDelivery
    let age: TimeInterval?
    let open: () -> Void
    let dismiss: () -> Void

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter
    }()

    private var canOpen: Bool { !row.target.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: row.teammateName)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    if let age, let text = Self.ageFormatter.string(from: age) {
                        Text(verbatim: text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(labelText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Button("Open chat", action: open)
                    .disabled(!canOpen)
                if row.state == .failed {
                    Button("Dismiss", action: dismiss)
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .modifier(RowActions(canOpen: canOpen, canDismiss: row.state == .failed, open: open, dismiss: dismiss))
    }

    private var labelText: String {
        switch row.label {
        case .queued: return String(localized: "Queued")
        case .pickedUp: return String(localized: "Picked up")
        case .working: return String(localized: "Working on it")
        case .answerQuestion: return String(localized: "Waiting on you — answer its question")
        case .approveOrDeny: return String(localized: "Waiting on you — approve or deny")
        case .outcomeUnknown: return String(localized: "Outcome unknown")
        case .failed(let text): return String(localized: "Failed: \(Self.failureWords(text))")
        }
    }

    private static func failureWords(_ text: BotTeammateDelivery.FailureText) -> String {
        switch text {
        case .verbatim(let line): return line
        case .unknown: return String(localized: "unknown error")
        case .known(let code):
            switch code {
            case "provider_auth_or_access": return String(localized: "its model provider rejected the key")
            case "provider_quota_limit": return String(localized: "its provider is out of credits")
            case "provider_rate_limit": return String(localized: "its provider is rate-limiting")
            case "provider_server_error": return String(localized: "its provider is unreachable")
            case "missing_config": return String(localized: "it has no model set up")
            case "model_unavailable": return String(localized: "its model is unavailable")
            case "context_overflow": return String(localized: "its context is full")
            case "runtime_offline": return String(localized: "it is offline")
            case "queued_expired": return String(localized: "it never picked it up")
            case "delivery_timeout": return String(localized: "timed out")
            case "agent_blocked": return String(localized: "it is blocked")
            case "cancelled": return String(localized: "cancelled")
            default: return String(localized: "unknown error")
            }
        }
    }
}

private struct RowActions: ViewModifier {
    let canOpen: Bool
    let canDismiss: Bool
    let open: () -> Void
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if canOpen { Button("Open chat", action: open) }
            if canDismiss { Button("Dismiss", action: dismiss) }
        }
    }
}
