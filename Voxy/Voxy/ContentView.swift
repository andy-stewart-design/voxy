import Accelerate
import AVFoundation
import AppKit
import Combine
import SwiftUI

// MARK: - ShortcutBadge

struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.08)))
    }
}

// MARK: - BottomBarButton

struct BottomBarButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                ShortcutBadge(text: shortcut)
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && isEnabled ? Color.primary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - RecordingState

@MainActor
final class RecordingState: ObservableObject {
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var amplitudeSamples: [Float] = []

    private static let barCount = 12
    private var timerTask: Task<Void, Never>?

    func start() {
        elapsedSeconds = 0
        amplitudeSamples = []
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                elapsedSeconds += 1
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        amplitudeSamples = []
    }

    func addSample(_ rms: Float) {
        if amplitudeSamples.count >= Self.barCount {
            amplitudeSamples.removeFirst()
        }
        amplitudeSamples.append(rms)
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let samples: [Float]

    private static let barCount    = 12
    private static let barWidth:   CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let minHeight:  CGFloat = 3
    private static let maxHeight:  CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let rms        = i < samples.count ? CGFloat(samples[i]) : 0
                let normalized = min(rms * 30, 1.0)
                let height     = Self.minHeight + normalized * (Self.maxHeight - Self.minHeight)
                Capsule()
                    .frame(width: Self.barWidth, height: height)
                    .animation(.easeOut(duration: 0.08), value: height)
            }
        }
        .foregroundStyle(.primary)
        .frame(height: Self.maxHeight)
    }
}

// MARK: - TranscriptEditorState

final class TranscriptEditorState: ObservableObject {
    weak var textView: NSTextView?

    func insertAtCursor(_ text: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            let newPos = range.location + (text as NSString).length
            tv.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }
}

// MARK: - TranscriptEditor

struct TranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    let editorState: TranscriptEditorState
    @Environment(\.colorScheme) private var colorScheme

    static let fontSize:   CGFloat        = 18
    private static let fontWeight: NSFont.Weight = .light

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.insertionPointColor = .controlAccentColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        Self.applyStyle(to: textView)

        editorState.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        scrollView.appearance = appearance
        textView.appearance = appearance
        Self.applyStyle(to: textView)

        if textView.string != text {
            textView.string = text
        }
    }

    /// Applies font, color, and typing attributes. Called from both make and update
    /// so that changes to fontSize take effect without recreating the view.
    private static func applyStyle(to textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        textView.textColor = .labelColor
        textView.font = font
        textView.typingAttributes = [
            .foregroundColor: NSColor.labelColor,
            .font: font
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var transcription: TranscriptionManager
    @StateObject private var audio = AudioInputManager()
    @StateObject private var editorState = TranscriptEditorState()
    @StateObject private var recordingState = RecordingState()

    @State private var engine = AVAudioEngine()
    @State private var isRecording = false
    @State private var recordingURL: URL?
    @State private var errorMessage: String?
    @State private var accumulatedTranscript = ""
    @State private var eventMonitor: Any?
    @State private var shortcutChordActive = false

    var body: some View {
        VStack(spacing: 0) {
            transcriptArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 440)
        .background(.regularMaterial)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            accumulatedTranscript = ""
            installKeyboardShortcuts()
            configureWindow()
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

    // MARK: - Window Setup

    private func configureWindow() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    // MARK: - Subviews

    private var transcriptArea: some View {
        ZStack(alignment: .topLeading) {
            if accumulatedTranscript.isEmpty && transcription.state == .ready && !isRecording {
                Text("Record to start transcribing…")
                    .font(.system(size: TranscriptEditor.fontSize, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
            TranscriptEditor(text: $accumulatedTranscript, editorState: editorState)
                .opacity(accumulatedTranscript.isEmpty ? 0.01 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            statusIndicator
            Spacer()
            actionBar
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
    }

    // MARK: - Status Indicator (left)

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
                    recordingIndicator
                } else if let device = audio.currentDeviceName {
                    Text(device).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.default, value: transcription.state)
    }

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            Text(formattedElapsed)
                .font(.custom("SF Compact Display", size: 15))
                .monospacedDigit()
                .foregroundStyle(.primary)
            WaveformView(samples: recordingState.amplitudeSamples)
        }
    }

    private var formattedElapsed: String {
        let m = recordingState.elapsedSeconds / 60
        let s = recordingState.elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Action Bar (right)

    @ViewBuilder
    private var actionBar: some View {
        if case .ready = transcription.state {
            HStack(spacing: 2) {
                BottomBarButton(
                    title: isRecording ? "Stop" : "Record",
                    shortcut: "⌘ Right + ⌥"
                ) {
                    Task {
                        if isRecording { await stopAndTranscribe() }
                        else { await startRecording() }
                    }
                }
                .disabled(recordButtonDisabled)

                if !accumulatedTranscript.isEmpty {
                    Rectangle()
                        .fill(.primary.opacity(0.15))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)

                    BottomBarButton(
                        title: "Copy Transcription",
                        shortcut: "⌘ + Enter"
                    ) {
                        copyAndClose()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private var recordButtonDisabled: Bool {
        if isRecording { return false }
        if audio.readiness == .permissionDenied { return true }
        if transcription.state != .ready { return true }
        return false
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

        let state = recordingState
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            try? file.write(from: buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))

            Task { @MainActor in state.addSample(rms) }
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
        recordingState.start()
    }

    private func stopAndTranscribe() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        recordingState.stop()

        guard let url = recordingURL else { return }
        if let result = await transcription.transcribe(audioURL: url) {
            editorState.insertAtCursor(result + " ")
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
                    if isRecording { await stopAndTranscribe() }
                    else { await startRecording() }
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
