import AppKit
import CraneCore
import CraneUI
import SwiftUI
import TipKit

/// Promotes the process to a normal Dock app when it runs as a bare SwiftPM executable
/// (`swift run`), where macOS would otherwise treat it as a background accessory.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try? Tips.configure()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CraneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = EngineModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Crane") { showAbout() }
            }
        }
    }

    private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: CraneVersion.current,
            .init(rawValue: "Copyright"): CraneVersion.stackSummary,
        ])
    }
}
