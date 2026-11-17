import SwiftUI

/// The app's voice call (#1091), pinned above every screen: what the call is doing, Mute and End,
/// and a tap anywhere else goes back to the call's chat. After a call drops it says why, with
/// Call again. Nothing shows with no call and no notice. Only this bar reads the call, so the
/// screens under it don't redraw as its status changes.
struct LiveVoiceCallBar: View {
    private let owner = LiveVoiceCall.shared

    var body: some View {
        if let call = owner.call {
            LiveVoiceCallRow(call: call, owner: owner)
                .modifier(LiveVoiceCallBarStyle())
        } else if let drop = owner.drop {
            LiveVoiceCallDropRow(message: drop.message, owner: owner)
                .modifier(LiveVoiceCallBarStyle())
        }
    }

    /// What the bar says the call is doing. Muted wins over Listening, so the user sees the
    /// voice can't hear them.
    enum Phase: Equatable {
        case connecting, listening, muted, thinking, speaking

        @MainActor init?(_ call: HermesVoiceCall) {
            switch call.status {
            case .connecting: self = .connecting
            case .listening: self = call.isMuted ? .muted : .listening
            case .thinking: self = .thinking
            case .speaking: self = .speaking
            case .ended: return nil
            }
        }
    }
}

private struct LiveVoiceCallBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            // Runs up under the status bar and the Dynamic Island.
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

private struct LiveVoiceCallRow: View {
    let call: HermesVoiceCall
    let owner: LiveVoiceCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = LiveVoiceCallBar.Phase(call)
        HStack(spacing: 8) {
            Button(action: owner.requestReopen) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.green)
                        // Moves only while the voice speaks; still otherwise and under Reduce Motion.
                        .symbolEffect(.variableColor.iterative, options: .repeating,
                                      isActive: phase == .speaking && !reduceMotion)
                        .accessibilityHidden(true)
                    Text(statusText(phase))
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Return to call"))
            .accessibilityValue(Text(statusText(phase)))
            .accessibilityAddTraits(.updatesFrequently)

            Button { call.setMuted(!call.isMuted) } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(call.isMuted ? Color.red : Color(.appTextSecondary))
                    .contentShape(Rectangle())
                    .opacity(isLive(phase) ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            // The microphone is the session's until it is up.
            .disabled(!isLive(phase))
            .accessibilityLabel(Text(call.isMuted ? "Unmute" : "Mute"))

            Button { call.end() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End call"))
        }
    }

    private func isLive(_ phase: LiveVoiceCallBar.Phase?) -> Bool {
        switch phase {
        case .listening, .muted, .thinking, .speaking: true
        case .connecting, nil: false
        }
    }

    private func statusText(_ phase: LiveVoiceCallBar.Phase?) -> String {
        switch phase {
        case .connecting: String(localized: "Connecting…")
        case .listening: String(localized: "Listening")
        case .muted: String(localized: "Muted")
        case .thinking: String(localized: "Hermes is working")
        case .speaking: String(localized: "Speaking")
        // The bar is on its way out.
        case nil: ""
        }
    }
}

private struct LiveVoiceCallDropRow: View {
    let message: String
    let owner: LiveVoiceCall

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.red)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(AppFont.footnote())
                .foregroundStyle(.appPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: owner.callAgain) {
                Text("Call again")
                    .font(AppFont.footnote(weight: .semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Button(action: owner.dismissDrop) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.appTextSecondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss call notice"))
        }
    }
}
