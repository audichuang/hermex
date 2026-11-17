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

    var body: some View {
        let phase = LiveVoiceCallBar.Phase(call)
        HStack(spacing: 8) {
            Button(action: owner.requestReopen) {
                HStack(spacing: 8) {
                    LiveVoiceWaveform(level: call.audioLevel, tint: waveformTint(phase))
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

    /// Green for the voice, the accent for the user, grey while nothing can be heard.
    private func waveformTint(_ phase: LiveVoiceCallBar.Phase?) -> Color {
        switch phase {
        case .speaking: .green
        case .listening, .thinking: .accentColor
        case .muted, .connecting, nil: Color(.appTextSecondary)
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

/// The call's sound as bars that rise and fall with it: the voice's while it speaks, the user's
/// microphone otherwise. The transport reads the level ten times a second while the call is up, so
/// the bars move only with sound and lie flat in silence. Under Reduce Motion they stay still and
/// only light up while there is sound.
struct LiveVoiceWaveform: View {
    let level: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tallest in the middle, like a voice memo's level meter.
    private static let profile: [Double] = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]
    private static let height: CGFloat = 22
    private static let minHeight: CGFloat = 3

    var body: some View {
        let loudness = Self.loudness(level)
        HStack(spacing: 2.5) {
            ForEach(Self.profile.indices, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(reduceMotion && loudness == 0 ? 0.35 : 1))
                    .frame(width: 3, height: barHeight(index, loudness))
            }
        }
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: level)
    }

    private func barHeight(_ index: Int, _ loudness: Double) -> CGFloat {
        let shape = Self.profile[index]
        if reduceMotion { return Self.minHeight + (Self.height - Self.minHeight) * shape * 0.6 }
        // Each reading sways the bars apart, so they don't scale as one block.
        let sway = 0.7 + 0.3 * abs(sin(level * 997 + Double(index) * 0.9))
        return Self.minHeight + (Self.height - Self.minHeight) * loudness * shape * sway
    }

    /// WebRTC's linear `audioLevel` mapped from -50 dB (flat) to -10 dB (full height), so quiet
    /// speech still shows.
    static func loudness(_ level: Double) -> Double {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level) + 50) / 40))
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
