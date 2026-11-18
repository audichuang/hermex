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
            LiveVoiceCallOrb(call: call, mood: LiveVoiceOrb.Mood(phase))
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
    let mood: LiveVoiceOrb.Mood

    var body: some View { LiveVoiceOrb(level: call.audioLevel, mood: mood) }
}

/// A glowing orb of flowing colour: a mesh gradient in a circle, a soft halo of the same colours
/// and a glassy highlight. Each mood has its own colours. The colours flow and the orb swells
/// only with the call's sound, and drift slowly while Hermes works; in silence they hold still.
/// Under Reduce Motion the orb keeps its shape and only its colours change.
struct LiveVoiceOrb: View {
    let level: Double
    let mood: Mood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the colours have flowed. It advances with each reading, more for louder ones.
    @State private var flow = 0.0

    enum Mood: Equatable {
        case idle, listening, speaking, thinking, muted

        init(_ phase: LiveVoiceCallBar.Phase?) {
            switch phase {
            case .listening: self = .listening
            case .speaking: self = .speaking
            case .thinking: self = .thinking
            case .muted: self = .muted
            case .connecting, .reconnecting, nil: self = .idle
            }
        }

        /// Nine colours for the 3 × 3 mesh, edges darker than the middle.
        var colors: [Color] {
            func rgb(_ hex: UInt32) -> Color {
                Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
            }
            let hexes: [UInt32] = switch self {
            // Ocean: you talk, it listens.
            case .listening: [0x3A2BD9, 0x2F7BFF, 0x00C2FF, 0x6A3DF0, 0x5EC8FF, 0x2EE6D6, 0x1E40AF, 0x7C5CFF, 0x22D3EE]
            // Aurora: Hermes talks.
            case .speaking: [0x0EA5A4, 0x22C55E, 0xA3E635, 0x06B6D4, 0x6EE7B7, 0xFDE047, 0x0F766E, 0x10B981, 0x84CC16]
            // Dusk: Hermes works on it.
            case .thinking: [0x7C3AED, 0xDB2777, 0xF97316, 0xA855F7, 0xF472B6, 0xFBBF24, 0x4C1D95, 0xC026D3, 0xFB7185]
            case .muted: [0x4B5563, 0x6B7280, 0x9CA3AF, 0x6B7280, 0xD1D5DB, 0x9CA3AF, 0x374151, 0x6B7280, 0x9CA3AF]
            case .idle: [0x334155, 0x475569, 0x64748B, 0x475569, 0x94A3B8, 0x64748B, 0x1E293B, 0x475569, 0x64748B]
            }
            return hexes.map(rgb)
        }
    }

    var body: some View {
        let loudness = reduceMotion ? 0 : LiveVoiceWaveform.loudness(level)
        ZStack {
            mesh
                .clipShape(Circle())
                .blur(radius: 36)
                .opacity(0.55 + 0.3 * loudness)
                .scaleEffect(1.0 + 0.3 * loudness)
            mesh
                .clipShape(Circle())
                .overlay {
                    // Glassy light from the top left, and a thin rim.
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                                 center: UnitPoint(x: 0.32, y: 0.25), startRadius: 2, endRadius: 90))
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .scaleEffect(0.8 + 0.12 * loudness)
        }
        .frame(width: 240, height: 240)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .animation(.easeInOut(duration: 0.6), value: mood)
        .onChange(of: level) {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.12)) { flow += 0.06 + 0.5 * loudness }
        }
        // While Hermes works the call is quiet, so the colours drift on their own, slowly.
        .task(id: mood == .thinking && !reduceMotion) {
            guard mood == .thinking, !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.linear(duration: 0.25)) { flow += 0.05 }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var mesh: some View {
        let f = flow
        func wobble(_ speed: Double, _ offset: Double) -> Float { Float(0.16 * sin(f * speed + offset)) }
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + wobble(1.3, 0), 0], [1, 0],
                [0, 0.5 + wobble(0.9, 1)], [0.5 + wobble(1.1, 2), 0.5 + wobble(1.7, 3)], [1, 0.5 + wobble(1.2, 4)],
                [0, 1], [0.5 + wobble(1.5, 5), 1], [1, 1],
            ],
            colors: mood.colors
        )
        // The colours turn as they flow, so the orb never looks like a still picture.
        .rotationEffect(.radians(f * 0.4))
        .scaleEffect(1.42)
    }
}
