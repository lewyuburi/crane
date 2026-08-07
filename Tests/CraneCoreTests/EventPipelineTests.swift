import DockerAPI
import Foundation
import Testing

@testable import CraneCore

/// Opt-in: needs a provisioned engine on this machine.
///
///     CRANE_INTEGRATION=1 swift test --filter EventPipelineTests
///
/// This is the one test that proves the central claim of the rewrite — that the container list
/// follows the engine without polling. Everything else about the reducer is unit-tested; this
/// checks the whole chain: real daemon → `/events` → feed → reducer → coalesced fetch → store.
@Suite("Event pipeline against the live daemon", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CRANE_INTEGRATION"] == "1"
                && DockerSocket.socktainer.exists))
@MainActor
struct EventPipelineTests {
    /// How long a change may take to reach the store. The coalescing window is 60 ms, so a second
    /// is generous — and still far under the 3 s poll the old app lived with.
    static let deadline = Duration.seconds(2)

    @Test("A container created, started and removed elsewhere shows up without a manual reload")
    func followsTheEngine() async throws {
        let client = DockerClient()
        defer { Task { await client.shutdown() } }
        let store = WorkspaceStore(client: client)
        let feed = EventFeed(client: client)
        let name = "crane-pipeline-test"
        try? await client.remove(name, force: true)

        // Consume the feed exactly as the app does.
        let pump = Task { @MainActor in
            for await signal in await feed.signals() {
                switch signal {
                case .resync: await store.reloadAll()
                case let .event(event): store.handle(event)
                default: break
                }
            }
        }
        defer { pump.cancel() }
        try await expect("the initial snapshot") { store.isLoaded }

        // Create it through the API — the store is told nothing directly.
        try await client.create(ContainerSpec(image: "alpine:3.22", command: ["sleep", "60"]), name: name)
        try await expect("the new container to appear") {
            store.containers.contains { $0.name == name }
        }

        try await client.start(name)
        try await expect("it to be running") {
            store.containers.first { $0.name == name }?.isRunning == true
        }

        try await client.stop(name, timeout: 1)
        try await expect("it to be stopped") {
            let container = store.containers.first { $0.name == name }
            return container != nil && container?.isRunning == false
        }

        try await client.remove(name)
        try await expect("it to disappear") {
            !store.containers.contains { $0.name == name }
        }
    }

    /// Polls the *store* (never the daemon) until the condition holds or the deadline passes.
    private func expect(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < Self.deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out waiting for \(what)")
    }
}
