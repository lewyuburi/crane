import AppKit
import CraneCore
import SwiftUI

/// Compact status menu for the menu bar extra.
public struct MenuBarStatusView: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button(statusTitle) {}
            .disabled(true)
        if model.phase == .ready {
            Button(runningCaption) {}
                .disabled(true)
        }

        Divider()

        Button("Open Crane") {
            AppPresence.showMainWindow(openWindow)
        }
        .keyboardShortcut("o")

        if model.phase == .ready {
            Button("Stop Engine") {
                Task { await model.stopEngine() }
            }
        } else if model.phase == .needsAttention || model.phase == .needsSetup {
            Button("Start Engine") {
                Task {
                    if model.phase == .needsSetup {
                        await model.provision()
                    } else {
                        await model.repair(.startDaemon)
                    }
                }
            }
            .disabled(model.phase == .working || model.phase == .checking)
        }

        Divider()

        Button("Quit Crane") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .onReceive(NotificationCenter.default.publisher(for: AppPresence.openMainWindow)) { _ in
            AppPresence.showMainWindow(openWindow)
        }
        .task {
            guard !model.previewLocked else { return }
            model.startWatching()
            await model.refresh()
            if model.phase == .ready { await model.workspace.reloadAll() }
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .checking: return "Checking…"
        case .working: return "Working…"
        case .ready: return "Engine running"
        case .needsSetup: return "Setup needed"
        case .needsAttention: return "Engine needs attention"
        }
    }

    private var runningCaption: String {
        let n = model.workspace.containers.filter(\.isRunning).count
        return n == 1 ? "1 container running" : "\(n) containers running"
    }
}

/// Dock / activation helpers shared by the menu bar and window lifecycle.
@MainActor
public enum AppPresence {
    public static let mainWindowID = "main"
    public static let openMainWindow = Notification.Name("craneOpenMainWindow")

    public static func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func hideFromDock() {
        NSApp.setActivationPolicy(.accessory)
    }

    public static func showMainWindow(_ openWindow: OpenWindowAction) {
        showInDock()
        openWindow(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
