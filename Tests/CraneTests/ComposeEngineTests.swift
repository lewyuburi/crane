import Testing
import Foundation
@testable import CraneKit

/// The Compose engine is UI-agnostic, so these tests run with no @MainActor and no SwiftUI —
/// the same way a future docker-compose-compatible CLI would drive it.
struct ComposeEngineTests {
    private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    private func collect(_ stream: AsyncStream<ComposeEvent>) async -> (logs: [String], failures: [String]) {
        var logs: [String] = [], failures: [String] = []
        for await event in stream {
            switch event {
            case .log(let s): logs.append(s)
            case .failure(let m): failures.append(m)
            }
        }
        return (logs, failures)
    }

    private func parse(_ yaml: String, name: String) throws -> ComposeProject {
        try ComposeParsing.parse(yaml: yaml, baseDir: tmp, projectNameOverride: name)
    }

    @Test func upStackUsesDefaultNetworkAndCompositeNames() async throws {
        let project = try parse("""
        services:
          app:
            image: app
          db:
            image: postgres
        """, name: "stk")
        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "stk-app", image: "app", status: .running, addresses: ["10.0.0.2"],
                      labels: ["com.docker.compose.project": "stk", "com.docker.compose.service": "app"]),
            Container(id: "stk-db", image: "postgres", status: .running, addresses: ["10.0.0.3"],
                      labels: ["com.docker.compose.project": "stk", "com.docker.compose.service": "db"]),
        ])

        let (logs, failures) = await collect(ComposeEngine(cli: fake).up(project))

        #expect(failures.isEmpty)
        #expect(logs.contains("Done."))
        #expect(await fake.networksCreated.contains("default"))
        let runs = await fake.runDetachedArgs
        #expect(runs.count == 2)
        for r in runs { #expect(r.firstIndex(of: "--network").map { r[$0 + 1] } == "default") }
        let names = Set(runs.compactMap { r in r.firstIndex(of: "--name").map { r[$0 + 1] } })
        #expect(names == ["stk-app", "stk-db"])
    }

    @Test func upEmitsFailureWhenRunFails() async throws {
        let project = try parse("services:\n  web:\n    image: nginx\n", name: "solo")
        let fake = FakeCLI()
        await fake.setFailOnRun(true)
        let (_, failures) = await collect(ComposeEngine(cli: fake).up(project))
        #expect(!failures.isEmpty)   // the run error surfaces as a failure event, not silently
    }

    @Test func wireHostsPassesHostileServiceNamesAsDataNotShell() async throws {
        // Security regression: a service name with shell metacharacters must be passed as a
        // positional argument (data), never interpolated into the `sh -c` script.
        let project = try parse("services:\n  app:\n    image: a\n  db:\n    image: p\n", name: "p")
        let evil = "x'; touch /pwned; echo '"
        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "p-app", image: "a", status: .running, addresses: ["10.0.0.2"],
                      labels: ["com.docker.compose.project": "p", "com.docker.compose.service": "app"]),
            Container(id: "p-db", image: "p", status: .running, addresses: ["10.0.0.3"],
                      labels: ["com.docker.compose.project": "p", "com.docker.compose.service": evil]),
        ])
        for await _ in ComposeEngine(cli: fake).up(project) {}

        let cmds = await fake.execCommands
        #expect(!cmds.isEmpty)
        for cmd in cmds {
            #expect(!cmd[2].contains("touch /pwned"))  // payload is NOT in the script
            #expect(cmd[2].contains("$@"))              // script iterates positional args
        }
        // …but the entry IS present as a later (data) argument.
        #expect(cmds.contains { $0.dropFirst(3).contains { $0.contains(evil) } })
    }

    @Test func downStopsAndDeletesOnlyProjectContainers() async {
        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "stk-app", image: "a", status: .running, labels: ["com.docker.compose.project": "stk"]),
            Container(id: "stk-db", image: "p", status: .running, labels: ["com.docker.compose.project": "stk"]),
            Container(id: "other", image: "x", status: .running, labels: ["com.docker.compose.project": "zzz"]),
        ])
        await ComposeEngine(cli: fake).down("stk")
        #expect(await fake.stoppedIDs == ["stk-app", "stk-db"])
        #expect(await fake.deletedIDs == ["stk-app", "stk-db"])
    }
}
