import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var transcription: TranscriptionManager
    @StateObject private var audio = AudioInputManager()

    @State private var engine = AVAudioEngine()
    @State private var isRecording = false
    @State private var recordingURL: URL?
    @State private var errorMessage: String?
    @State private var accumulatedTranscript = ""
    @State private var eventMonitor: Any?
    @State private var shortcutChordActive = false

    var body: some View {
        VStack(spacing: 0) {
            // Main transcript area
            transcriptArea

            Divider()

            // Bottom bar: state feedback + action hints
            bottomBar
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            accumulatedTranscript = ""   // fresh session each open
            installKeyboardShortcuts()
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        .task {
            await requestMicrophonePermissionIfNeeded()
        }
    }

    // MARK: - Subviews

    private var transcriptArea: some View {
        ZStack(alignment: .topLeading) {
            if accumulatedTranscript.isEmpty && transcription.state == .ready && !isRecording {
                Text("Record to start transcribing…")
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
            TextEditor(text: $accumulatedTranscript)
                .scrollContentBackground(.hidden)
                .padding(8)
                .opacity(accumulatedTranscript.isEmpty ? 0.01 : 1) // keep it tappable when empty
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            // Left: status
            statusIndicator

            Spacer()

            // Right: action hints
            HStack(spacing: 16) {
                recordButton
                if !accumulatedTranscript.isEmpty {
                    copyCloseButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusIndicator: some View {
        Group {
            switch transcription.state {
            case .loading(let message):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message):
                HStack(spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Button("Retry") { transcription.retry() }.font(.caption)
                }
            case .ready:
                if audio.readiness == .waitingForBluetooth {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Switching Bluetooth audio…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if isRecording {
                    Text("Recording").font(.caption).foregroundStyle(.green)
                } else if let device = audio.currentDeviceName {
                    Text(device).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.default, value: transcription.state)
    }

    private var recordButton: some View {
        Button(isRecording ? "Stop" : "Record") {
            Task {
                if isRecording {
                    await stopAndTranscribe()
                } else {
                    await startRecording()
                }
            }
        }
        .disabled(recordButtonDisabled)
    }

    private var recordButtonDisabled: Bool {
        if isRecording { return false }                        // always allow stopping
        if audio.readiness == .permissionDenied { return true }
        if transcription.state != .ready { return true }      // loading / transcribing / failed
        return false
    }

    private var copyCloseButton: some View {
        Button("Copy & Close") {
            copyAndClose()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(accumulatedTranscript.isEmpty)
    }

    // MARK: - Actions

    private func copyAndClose() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(accumulatedTranscript, forType: .string)
        NSApp.keyWindow?.close()
    }

    // MARK: - Recording Flow

    private func startRecording() async {
        errorMessage = nil
        recordingURL = nil

        guard await audio.waitUntilReady() else {
            errorMessage = switch audio.readiness {
            case .permissionDenied: "Microphone access denied — check System Settings"
            default:                "Audio input unavailable — check your device"
            }
            return
        }

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "Could not read audio format — try again"
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: tempURL, settings: inputFormat.settings)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            try? file.write(from: buffer)
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            errorMessage = error.localizedDescription
            return
        }

        recordingURL = tempURL
        isRecording = true
    }

    private func stopAndTranscribe() async {
        // Remove tap first — flushes and closes the AVAudioFile.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        guard let url = recordingURL else { return }
        if let result = await transcription.transcribe(audioURL: url) {
            if accumulatedTranscript.isEmpty {
                accumulatedTranscript = result
            } else {
                accumulatedTranscript += "\n\n" + result
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private func installKeyboardShortcuts() {
        // Right⌘ + Right⌥ — toggle record/stop.
        //
        // These are modifier-only keys so we listen for flagsChanged, not keyDown.
        // NSEvent doesn't expose left/right distinction in ModifierFlags, but the
        // raw value contains per-side bits: right command = 0x10, right option = 0x40.
        // We fire once when both transition from not-pressed → pressed.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let raw = event.modifierFlags.rawValue
            let rightCommandDown = raw & 0x10 != 0
            let rightOptionDown  = raw & 0x40 != 0
            let bothDown = rightCommandDown && rightOptionDown

            if bothDown && !shortcutChordActive {
                shortcutChordActive = true
                Task {
                    if isRecording {
                        await stopAndTranscribe()
                    } else {
                        await startRecording()
                    }
                }
            } else if !bothDown {
                shortcutChordActive = false
            }
            return event
        }
    }

    // MARK: - Permission

    private func requestMicrophonePermissionIfNeeded() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        await AVCaptureDevice.requestAccess(for: .audio)
        audio.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }
}
