import AppKit
import CraneCore
import CraneUI
import SwiftUI
import TipKit

/// Owns Dock visibility and “last window closed” behavior for the menu bar lifestyle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try? Tips.configure()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: AppPresence.openMainWindow, object: nil)
        }
        return true
    }

    @objc private func windowWillClose(_ note: Notification) {
        DispatchQueue.main.async {
            let remaining = NSApp.windows.filter { window in
                window.isVisible
                    && window.canBecomeMain
                    && !(window is NSPanel)
            }
            if remaining.isEmpty {
                AppPresence.hideFromDock()
            }
        }
    }
}

@main
struct CraneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = EngineModel()

    var body: some Scene {
        WindowGroup(id: AppPresence.mainWindowID) {
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

        MenuBarExtra("Crane", systemImage: "shippingbox.fill") {
            MenuBarStatusView()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)
    }

    private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: CraneVersion.current,
            .init(rawValue: "Copyright"): CraneVersion.stackSummary,
        ])
    }
}
