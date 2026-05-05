import AppKit
import SwiftUI

@main
struct VoxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var transcription = TranscriptionManager()

    var body: some Scene {
        MenuBarExtra("Voxy", systemImage: "waveform") {
            MenuView()
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

    var body: some View {
        Button("Settings") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Voxy") {
            NSApp.terminate(nil)
        }
    }
}
