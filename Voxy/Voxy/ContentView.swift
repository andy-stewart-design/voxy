import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioInputManager()

    // AVAudioEngine is a reference type. @State persists the instance across
    // view body re-evaluations — it is NOT recreated on each render.
    @State private var engine = AVAudioEngine()
    @State private var isRecording = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            statusLabel
            recordButton

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(minWidth: 340, minHeight: 220)
        .onAppear {
            // With .accessory activation policy, windows don't receive keyboard
            // focus automatically. This ensures the window is usable on open.
            NSApp.activate(ignoringOtherApps: true)
        }
        .task {
            await requestMicrophonePermissionIfNeeded()
        }
    }

    // MARK: - Subviews

    private var statusLabel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if audio.readiness == .waitingForBluetooth {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            .animation(.default, value: audio.readiness)

            if let device = audio.currentDeviceName {
                Text(device)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordButton: some View {
        Button(isRecording ? "Stop" : "Record") {
            Task {
                if isRecording {
                    stopRecording()
                } else {
                    await startRecording()
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .accentColor)
        .disabled(audio.readiness == .permissionDenied)
    }

    // MARK: - Recording Flow

    private func startRecording() async {
        errorMessage = nil

        guard await audio.waitUntilReady() else {
            errorMessage = switch audio.readiness {
            case .permissionDenied: "Microphone access denied — check System Settings"
            default:                "Audio input unavailable — check your device"
            }
            return
        }

        // Read the hardware format before installing the tap. The tap format
        // must match the hardware exactly — mismatches cause error -10868.
        // HFP Bluetooth devices often use 24000 Hz rather than the standard
        // 48000 Hz, so we can't assume a fixed rate.
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "Could not read audio format — try again"
            return
        }

        // A tap must be installed before engine.start() on macOS — the engine
        // won't initialize input/output nodes without at least one active tap.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { _, _ in
            // TODO: process captured audio buffers
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            errorMessage = error.localizedDescription
            return
        }

        isRecording = true
    }

    private func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    // MARK: - Permission

    private func requestMicrophonePermissionIfNeeded() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        await AVCaptureDevice.requestAccess(for: .audio)
        // Re-evaluate now that permission has been granted or denied.
        audio.refresh()
        // The system dialog causes .accessory apps to lose window visibility.
        // Re-activate to bring the settings window back to the front.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Presentation

    private var statusText: String {
        switch audio.readiness {
        case .unknown:             return "Detecting input…"
        case .waitingForBluetooth: return "Switching Bluetooth audio…"
        case .ready:               return isRecording ? "Recording" : "Ready"
        case .permissionDenied:    return "Microphone access denied"
        }
    }

    private var statusColor: Color {
        switch audio.readiness {
        case .permissionDenied:        return .red
        case .ready where isRecording: return .green
        default:                       return .primary
        }
    }
}
