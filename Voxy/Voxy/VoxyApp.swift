import AppKit
import SwiftUI

@main
struct VoxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var transcription = TranscriptionManager()

    var body: some Scene {
        MenuBarExtra("Voxy", systemImage: "waveform") {
            MenuView()
                .environmentObject(transcription)
        }
        .menuBarExtraStyle(.menu)

        Window("Voxy", id: "main") {
            ContentView()
                .environmentObject(transcription)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// Suppresses the dock icon. There is no SwiftUI-native API for this.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var transcription: TranscriptionManager

    var body: some View {
        Button("Settings") {
            openWindow(id: "main")
            // Move the window to the user's current Space rather than
            // switching to whichever Space it was last on.
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
        }

        Menu("Model") {
            Picker("Model", selection: Binding(
                get: { transcription.selectedModel },
                set: { transcription.switchModel(to: $0) }
            )) {
                ForEach(TranscriptionManager.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(transcription.state != .ready)

        Divider()
        Button("Quit Voxy") {
            NSApp.terminate(nil)
        }
    }
}
