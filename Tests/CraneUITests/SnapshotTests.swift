import AppKit
import CraneCore
import SwiftUI
import Testing

@testable import CraneUI

/// Renders the real screens to PNGs so the design can be reviewed — and reviewed again after a
/// change — without launching the app or taking a screenshot.
///
///     CRANE_SNAPSHOTS=/tmp/crane-ui swift test --filter SnapshotTests
///
/// Off by default: it writes files, and its value is in looking at them.
///
/// The views are hosted in a real window and captured through AppKit rather than rendered with
/// `ImageRenderer`, because the renderer draws a placeholder for `List`, `NavigationSplitView`
/// and scroll content — exactly the parts worth looking at. Capturing an app's own window needs
/// no screen-recording permission.
@Suite("Screen snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CRANE_SNAPSHOTS"] != nil))
@MainActor
struct SnapshotTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CRANE_SNAPSHOTS"] ?? NSTemporaryDirectory())
    }

    /// AppKit needs the app to have finished launching before the first window it draws is real;
    /// without this the first capture in a process comes out blank.
    @MainActor
    private static let ready: Bool = {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        NSApplication.shared.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return true
    }()

    private func snapshot(_ name: String, size: CGSize, @ViewBuilder _ content: () -> some View) throws {
        _ = Self.ready
        // A hosting *controller* rather than a bare view: that's what lets SwiftUI install its
        // toolbar into the window, so the captures show the search field and buttons too.
        let controller = NSHostingController(rootView:
            AnyView(content().environment(EngineModel.preview)))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(size)

        // Key and active, or every control draws in its inactive shade and the snapshot lies
        // about the contrast.
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        // Let SwiftUI settle: async loads, animations and the first layout pass.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        window.displayIfNeeded()
        controller.view.display()

        // Note: a NavigationSplitView's sidebar is a vibrancy view, and neither `cacheDisplay`
        // nor layer rendering captures its material — it comes out blank. The sidebar is
        // therefore snapshotted on its own, where it draws normally.
        let host = controller.view
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("couldn't encode \(name)")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: "\(name).png", directoryHint: .notDirectory))
        // Deliberately not closed: tearing a window down mid-suite leaves the next capture
        // without a key window, and every control then draws in its inactive shade.
        window.orderOut(nil)
    }

    @Test("Onboarding")
    func onboarding() throws {
        EngineModel.preview.seedPreview(
            status: PreviewFixtures.engineStatus(runtime: false, running: false, contextCurrent: nil),
            phase: .needsSetup)
        try snapshot("onboarding", size: CGSize(width: 900, height: 700)) { OnboardingView() }
    }

    @Test("Onboarding with a foreign Docker CLI")
    func onboardingForeign() throws {
        EngineModel.preview.seedPreview(
            status: PreviewFixtures.engineStatus(runtime: false, running: false,
                                                 foreignDockerPath: "/usr/local/bin/docker",
                                                 contextCurrent: nil),
            phase: .needsSetup)
        try snapshot("onboarding-foreign", size: CGSize(width: 900, height: 700)) { OnboardingView() }
    }

    @Test("Engine with no CLI pack")
    func engineNoCLI() throws {
        EngineModel.preview.seedPreview(status: PreviewFixtures.engineStatus(), phase: .ready)
        try snapshot("engine", size: CGSize(width: 720, height: 780)) {
            NavigationStack { EngineView() }
        }
    }

    @Test("Engine with a foreign Docker CLI")
    func engineForeign() throws {
        EngineModel.preview.seedPreview(
            status: PreviewFixtures.engineStatus(foreignDockerPath: "/usr/local/bin/docker",
                                                 contextCurrent: "desktop-linux"),
            phase: .ready)
        try snapshot("engine-foreign", size: CGSize(width: 720, height: 780)) {
            NavigationStack { EngineView() }
        }
    }

    @Test("Engine with the CLI pack installed")
    func enginePack() throws {
        EngineModel.preview.seedPreview(status: PreviewFixtures.engineStatus(cliPack: true), phase: .ready)
        try snapshot("engine-cli", size: CGSize(width: 720, height: 780)) {
            NavigationStack { EngineView() }
        }
    }

    /// The list and the detail are captured through the real window: on their own, outside a
    /// split view, SwiftUI never gives them a layout pass and they come out blank.
    @Test("Window with a container selected")
    func windowWithSelection() throws {
        EngineModel.preview.seedPreview(status: PreviewFixtures.engineStatus(), phase: .ready)
        try snapshot("detail", size: CGSize(width: 1280, height: 820)) {
            WorkspaceView(selection: .container("a1b2c3d4e5f6"))
        }
    }

    @Test("Sidebar")
    func sidebar() throws {
        EngineModel.preview.seedPreview(status: PreviewFixtures.engineStatus(), phase: .ready)
        try snapshot("sidebar", size: CGSize(width: 220, height: 620)) {
            NavigationStack { WorkspaceSidebar(section: .constant(.containers)) }
        }
    }

    @Test("Whole window")
    func window() throws {
        EngineModel.preview.seedPreview(status: PreviewFixtures.engineStatus(), phase: .ready)
        try snapshot("window", size: CGSize(width: 1280, height: 820)) { WorkspaceView() }
    }
}

private extension EngineModel {
    /// A model whose workspace is already populated. Its engine calls still go nowhere in
    /// particular, which is fine: snapshots only draw.
    ///
    /// One shared instance for the whole run, because it owns an `HTTPClient` — that type traps
    /// if it is deallocated without an explicit shutdown, and a per-test model would do exactly
    /// that. The app has the same lifetime rule: one model, alive for the process.
    @MainActor
    static let preview: EngineModel = {
        let model = EngineModel()
        model.workspace.seed(
            containers: PreviewFixtures.containers,
            images: PreviewFixtures.images,
            volumes: PreviewFixtures.volumes,
            networks: PreviewFixtures.networks)
        return model
    }()
}
