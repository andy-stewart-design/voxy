import AppKit
import SwiftUI

@main
struct VoxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Voxy", systemImage: "waveform") {
            MenuView()
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            ContentView()
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
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Voxy") {
            NSApp.terminate(nil)
        }
    }
}
