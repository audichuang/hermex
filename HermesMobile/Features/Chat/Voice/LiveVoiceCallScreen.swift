import AVFoundation
import AVKit
import SwiftUI

/// The voice call full screen (#1091): an orb that swells with the call's sound, what the call is
/// doing and the latest words, and floating glass buttons for the audio output, Mute and End.
/// Swiping it down or Minimize leaves the call running as the pill (`LiveVoiceCallBar`); Show chat
/// minimizes it over the call's chat, for an approval or the reply in full.
struct LiveVoiceCallScreen: View {
    private let owner = LiveVoiceCall.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground), Color.accentColor.opacity(0.12)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if let call = owner.call {
                LiveVoiceCallStage(call: call, owner: owner)
            }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct LiveVoiceCallStage: View {
    let call: HermesVoiceCall
    let owner: LiveVoiceCall

    var body: some View {
        let phase = LiveVoiceCallBar.Phase(call)
        VStack(spacing: 0) {
            HStack {
                LiveVoiceCallRoundButton(systemImage: "chevron.down", label: "Minimize call", action: owner.minimize)
                Spacer()
                LiveVoiceCallTimer(call: call, font: AppFont.body().monospacedDigit())
                Spacer()
                LiveVoiceCallRoundButton(systemImage: "bubble.left.and.text.bubble.right", label: "Show chat",
                                         action: owner.showChat)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer(minLength: 24)
            LiveVoiceCallOrb(call: call, tint: phase?.tint ?? .secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Text(phase?.text ?? "")
                    .font(AppFont.headline())
                    .foregroundStyle(.appPrimary)
                    .accessibilityAddTraits(.updatesFrequently)
                if let caption = call.caption, !caption.text.isEmpty {
                    Text(verbatim: caption.text)
                        .font(AppFont.body())
                        .foregroundStyle(caption.speaker == .user ? Color(.appTextSecondary) : Color(.appText))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 520)
                }
            }
            .padding(.horizontal, 28)
            .frame(minHeight: 120, alignment: .top)

            LiveVoiceCallControls(call: call, isLive: phase?.isLive == true)
                .padding(.bottom, 28)
        }
    }
}

/// Glass circles for the output route, Mute and End, each with its name under it.
private struct LiveVoiceCallControls: View {
    let call: HermesVoiceCall
    let isLive: Bool
    @State private var route = LiveVoiceCallControls.currentRoute()

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            control(route.name) {
                // Apple's own route picker (iPhone, Speaker, AirPods and other Bluetooth outputs),
                // drawn as the current output's symbol.
                ZStack {
                    Image(systemName: route.symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color(.appText))
                        .allowsHitTesting(false)
                    AudioRoutePicker()
                }
                .frame(width: 72, height: 72)
                .adaptiveGlass(isInteractive: true, in: Circle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Audio output"))
                .accessibilityValue(Text(verbatim: route.name))
            }

            control(call.isMuted ? String(localized: "Unmute") : String(localized: "Mute")) {
                Button { call.setMuted(!call.isMuted) } label: {
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(call.isMuted ? Color.white : Color(.appText))
                        .frame(width: 72, height: 72)
                        .background(call.isMuted ? Color.red : Color.clear, in: Circle())
                        .adaptiveGlass(isInteractive: true, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isLive)
                .opacity(isLive ? 1 : 0.4)
                .accessibilityLabel(Text(call.isMuted ? "Unmute" : "Mute"))
            }

            control(String(localized: "End call")) {
                Button { call.end() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.red, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("End call"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            route = Self.currentRoute()
        }
    }

    private func control(_ name: String, @ViewBuilder _ button: () -> some View) -> some View {
        VStack(spacing: 8) {
            button()
            Text(verbatim: name)
                .font(AppFont.caption())
                .foregroundStyle(Color(.appTextSecondary))
                .lineLimit(1)
                .frame(width: 88)
                .accessibilityHidden(true)
        }
    }

    /// The output the call plays on now: its name as the system gives it ("Speaker",
    /// "AirPods Pro") and a symbol for its kind.
    static func currentRoute() -> (name: String, symbol: String) {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return (String(localized: "Audio output"), "speaker.wave.2.fill")
        }
        let symbol = switch output.portType {
        case .builtInReceiver: "iphone"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: "airpods"
        case .headphones, .usbAudio: "headphones"
        case .carAudio: "car.fill"
        case .airPlay: "airplay.audio"
        default: "speaker.wave.2.fill"
        }
        return (output.portName, symbol)
    }
}

/// `AVRoutePickerView`, the system's audio output picker.
private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        // Invisible: the symbol under it shows the current output.
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// A small glass circle for the full screen's top corners.
private struct LiveVoiceCallRoundButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(.appText))
                .frame(width: 44, height: 44)
                .adaptiveGlass(isInteractive: true, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Reads the call's level here, so its ten readings a second redraw only the orb.
private struct LiveVoiceCallOrb: View {
    let call: HermesVoiceCall
    let tint: Color

    var body: some View { LiveVoiceOrb(level: call.audioLevel, tint: tint) }
}

/// A glowing orb that swells with the call's sound and settles in silence. It moves only when a
/// reading changes; under Reduce Motion it keeps its size.
struct LiveVoiceOrb: View {
    let level: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let loudness = reduceMotion ? 0 : LiveVoiceWaveform.loudness(level)
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
                .scaleEffect(1 + 0.28 * loudness)
            Circle()
                .fill(tint.opacity(0.22))
                .scaleEffect(0.86 + 0.16 * loudness)
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.65), tint],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 4, endRadius: 120))
                .scaleEffect(0.7 + 0.1 * loudness)
                .shadow(color: tint.opacity(0.45), radius: 24)
        }
        .frame(width: 220, height: 220)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
    }
}
