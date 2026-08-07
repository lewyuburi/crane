import Foundation
import Testing

@testable import EngineControl

/// Opt-in: these download ~230 MB from Apple, socktainer and Docker, so they don't run in CI or
/// on a normal `swift test`. They are the only proof that the real published assets still match
/// the pinned digests and unpack where the layout expects — run them when bumping the stack:
///
///     CRANE_INTEGRATION=1 swift test --filter InstallerIntegration
@Suite("Installer against the real artifacts",
       .enabled(if: ProcessInfo.processInfo.environment["CRANE_INTEGRATION"] == "1"))
struct InstallerIntegrationTests {
    private func temporaryLayout() -> StackLayout {
        StackLayout(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "crane-integration-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test("Every pinned artifact downloads, verifies and lands as a working binary",
          arguments: EngineComponent.allCases)
    func installsComponent(_ component: EngineComponent) async throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let installer = StackInstaller(layout: layout)
        let artifact = StackManifest.current.artifact(for: component)

        let executable = try await installer.install(artifact)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let link = layout.link(for: component)
        #expect(FileManager.default.isExecutableFile(atPath: link.path))
        let script = try String(contentsOf: link, encoding: .utf8)
        #expect(LauncherScript.target(of: script) == executable.path(percentEncoded: false))

        // The binary must actually report the version we pinned — a digest match proves the
        // bytes, this proves we unpacked the right bytes.
        let reported = await installer.installedVersion(of: component)
        #expect(reported == artifact.version)
    }

    @Test("A tampered artifact is rejected before anything is unpacked")
    func refusesBadDigest() async throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let good = StackManifest.current.compose
        let tampered = Artifact(component: good.component, version: good.version, url: good.url,
                                sha256: String(repeating: "a", count: 64), layout: good.layout)

        await #expect(throws: EngineError.self) {
            try await StackInstaller(layout: layout).install(tampered)
        }
        #expect(!FileManager.default.fileExists(atPath: layout.executable(for: tampered).path))
    }
}
