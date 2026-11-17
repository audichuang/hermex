import SwiftUI

/// The app's voice call (#1091) as a floating pill above every screen while the call is
/// minimized: what it is doing, its timer, Mute and End; a tap anywhere else opens the
/// full-screen call. After a call drops it says why, with Call again. Nothing shows with no call,
/// no notice, or while the call fills the screen. Only this pill reads the call, so the screens
/// under it don't redraw as its status changes.
struct LiveVoiceCallBar: View {
    private let owner = LiveVoiceCall.shared

    var body: some View {
        if let call = owner.call {
            if !owner.isExpanded {
                LiveVoiceCallRow(call: call, owner: owner)
                    .modifier(LiveVoiceCallPillStyle())
            }
        } else if let drop = owner.drop {
            LiveVoiceCallDropRow(message: drop.message, owner: owner)
                .modifier(LiveVoiceCallPillStyle())
        }
    }

    /// What the call is doing. Muted wins over Listening, so the user sees the voice can't hear
    /// them.
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

        var text: String {
            switch self {
            case .connecting: String(localized: "Calling…")
            case .listening: String(localized: "Listening")
            case .muted: String(localized: "Muted")
            case .thinking: String(localized: "Hermes is working")
            case .speaking: String(localized: "Speaking")
            }
        }

        /// Green for the voice, the accent for the user, grey while nothing can be heard.
        var tint: Color {
            switch self {
            case .speaking: .green
            case .listening, .thinking: .accentColor
            case .muted, .connecting: Color(.appTextSecondary)
            }
        }

        /// The session is up, so the microphone is the call's to mute.
        var isLive: Bool { self != .connecting }
    }
}

/// A glass capsule floating under the status bar with a margin on each side. The screens under
/// it still start below it, so it never covers a navigation bar.
private struct LiveVoiceCallPillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(maxWidth: 520)
            .adaptiveGlass(isInteractive: true, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
    }
}

private struct LiveVoiceCallRow: View {
    let call: HermesVoiceCall
    let owner: LiveVoiceCall

    var body: some View {
        let phase = LiveVoiceCallBar.Phase(call)
        HStack(spacing: 4) {
            Button(action: owner.expand) {
                HStack(spacing: 8) {
                    LiveVoiceCallWaveform(call: call, tint: phase?.tint ?? .secondary)
                        .accessibilityHidden(true)
                    Text(phase?.text ?? "")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)
                    LiveVoiceCallTimer(call: call)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Return to call"))
            .accessibilityValue(Text(phase?.text ?? ""))
            .accessibilityAddTraits(.updatesFrequently)

            Button { call.setMuted(!call.isMuted) } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(call.isMuted ? Color.red : Color(.appTextSecondary))
                    .contentShape(Rectangle())
                    .opacity(phase?.isLive == true ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(phase?.isLive != true)
            .accessibilityLabel(Text(call.isMuted ? "Unmute" : "Mute"))

            Button { call.end() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End call"))
        }
    }
}

/// The call's running time once the session is up. The system ticks it, so nothing redraws
/// each second.
struct LiveVoiceCallTimer: View {
    let call: HermesVoiceCall
    var font: Font = AppFont.footnote()

    var body: some View {
        if let connectedAt = call.connectedAt {
            Text(connectedAt, style: .timer)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(Color(.appTextSecondary))
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }
}

/// Reads the call's level here, so its ten readings a second redraw only the bars.
private struct LiveVoiceCallWaveform: View {
    let call: HermesVoiceCall
    let tint: Color

    var body: some View { LiveVoiceWaveform(level: call.audioLevel, tint: tint) }
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
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
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
