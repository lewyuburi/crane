import AppleContainer
import DockerAPI
import EngineControl
import Foundation
import Testing

@testable import CraneCore

/// Opt-in: needs a provisioned engine.
///
///     CRANE_INTEGRATION=1 swift test --filter FileBrowserLiveTests
///
/// Copying files is the one feature where a wrong assumption is invisible until someone loses
/// data, so it's exercised against a real container: list a directory, take a file out, put one
/// back, and read it from inside.
@Suite("File browser against the live daemon", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CRANE_INTEGRATION"] == "1"
                && DockerSocket.socktainer.exists))
struct FileBrowserLiveTests {
    @Test("Lists, downloads and uploads")
    func roundTrip() async throws {
        let client = DockerClient()
        defer { Task { await client.shutdown() } }
        let engine = Engine()
        let runtime = engine.runtime
        let name = "crane-files-test"
        try? await client.remove(name, force: true)
        try await client.run(ContainerSpec(image: "alpine:3.22", command: ["sleep", "120"]), name: name)
        defer { Task { try? await client.remove(name, force: true) } }

        let browser = FileBrowser(client: client, runtime: runtime, containerID: name)

        let etc = try await browser.list("/etc")
        #expect(etc.contains { $0.name == "alpine-release" && $0.kind == .file })
        #expect(etc.contains { $0.name == "apk" && $0.isDirectory })
        #expect(etc.allSatisfy { $0.name != "." && $0.name != ".." })

        // Out: a known file lands on disk with its real contents.
        let downloaded = FileManager.default.temporaryDirectory
            .appending(path: "crane-alpine-release", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: downloaded)
        try await browser.download("/etc/alpine-release", to: downloaded)
        let release = try String(contentsOf: downloaded, encoding: .utf8)
        #expect(release.hasPrefix("3.22"))
        try? FileManager.default.removeItem(at: downloaded)

        // In: a file we make here shows up inside the container, with its bytes intact.
        let source = FileManager.default.temporaryDirectory
            .appending(path: "crane-upload-probe.txt", directoryHint: .notDirectory)
        try "hello from the host\n".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        try await browser.upload([source], to: "/tmp")

        let listing = try await browser.list("/tmp")
        #expect(listing.contains { $0.name == "crane-upload-probe.txt" })
        let inside = try await runtime.output(containerID: name,
                                              command: ["cat", "/tmp/crane-upload-probe.txt"])
        #expect(inside.contains("hello from the host"))
    }
}
