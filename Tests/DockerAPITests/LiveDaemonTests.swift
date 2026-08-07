import Foundation
import Testing

@testable import DockerAPI

/// Opt-in: runs against the socket on this machine, so it needs a provisioned Crane.
///
///     CRANE_INTEGRATION=1 swift test --filter LiveDaemonTests
///
/// The fake daemon proves the transport; this proves the models still match what socktainer
/// actually sends, which is the thing that silently drifts when either side updates.
@Suite("Live daemon", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CRANE_INTEGRATION"] == "1"
                && DockerSocket.socktainer.exists))
struct LiveDaemonTests {
    private func withClient(_ body: (DockerClient) async throws -> Void) async throws {
        let client = DockerClient()
        defer { Task { await client.shutdown() } }
        try await body(client)
    }

    @Test("The daemon identifies itself as the pinned pair")
    func reportsVersions() async throws {
        try await withClient { client in
            #expect(await client.ping())
            let version = try await client.version()
            #expect(version.apiVersion.contains("1.51"))
            let info = try await client.info()
            #expect(info.cpus > 0)
        }
    }

    @Test("Listing every resource decodes without losing rows")
    func listsResources() async throws {
        try await withClient { client in
            let containers = try await client.containers()
            let images = try await client.images()
            let volumes = try await client.volumes()
            let networks = try await client.networks()
            #expect(networks.contains { $0.name == "default" }, "the runtime always has a default network")
            // Every row must carry an id: a blank one means a decoding key drifted.
            #expect(containers.allSatisfy { !$0.id.isEmpty })
            #expect(images.allSatisfy { !$0.id.isEmpty })
            #expect(volumes.allSatisfy { !$0.name.isEmpty })
        }
    }

    @Test("A container's whole lifecycle works over the socket")
    func runsAContainer() async throws {
        try await withClient { client in
            let name = "crane-live-test"
            try? await client.remove(name, force: true)

            let spec = ContainerSpec(image: "alpine:3.22",
                                     command: ["sh", "-c", "echo hello from crane; sleep 30"],
                                     labels: ["dev.crane.test": "1"])
            try await client.run(spec, name: name)

            let detail = try await client.container(name)
            #expect(detail.state.running)
            #expect(detail.name == name)

            // Logs: the framing is the part most likely to break.
            var output = ""
            for try await chunk in client.logs(name, follow: false, tail: 10) { output += chunk.text }
            #expect(output.contains("hello from crane"))

            let sample = try await client.statsOnce(name)
            #expect(sample.memoryLimit > 0)

            try await client.stop(name, timeout: 1)
            #expect(try await client.container(name).state.running == false)
            try await client.remove(name)
            let remaining = try await client.containers()
            #expect(!remaining.contains { $0.name == name })
        }
    }
}
