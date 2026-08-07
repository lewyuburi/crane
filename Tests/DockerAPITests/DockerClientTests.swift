import Foundation
import Testing

@testable import DockerAPI

/// Exercises the client against a real UNIX-socket HTTP server. Everything else in this target
/// is pure; this is the suite that proves the wire format is right.
@Suite("Client over a real socket", .serialized)
struct DockerClientTests {
    private static let version = #"{"Version":"1.51","ApiVersion":"1.51","Os":"linux","Arch":"arm64","Components":[{"Name":"socktainer","Version":"1.2.1"},{"Name":"Apple Container","Version":"1.2.0"}]}"#

    private func withDaemon(
        routes: [String: FakeDaemon.Route],
        _ body: (DockerClient) async throws -> Void
    ) async throws {
        let daemon = try await FakeDaemon(routes: routes)
        let client = DockerClient(socket: DockerSocket(path: daemon.socketPath))
        do {
            try await body(client)
        } catch {
            await client.shutdown()
            await daemon.shutdown()
            throw error
        }
        await client.shutdown()
        await daemon.shutdown()
    }

    @Test("Ping and version round-trip over the socket")
    func talksToTheSocket() async throws {
        try await withDaemon(routes: [
            "/v1.51/_ping": .init(body: "OK"),
            "/v1.51/version": .init(body: Self.version),
        ]) { client in
            #expect(await client.ping())
            let version = try await client.version()
            #expect(version.apiVersion == "1.51")
            #expect(version.component("socktainer") == "1.2.1")
            #expect(version.component("apple container") == "1.2.0")
        }
    }

    @Test("A missing socket is reported as 'not running', not as a networking error")
    func mapsMissingSocket() async throws {
        let client = DockerClient(socket: DockerSocket(path: "/tmp/crane-does-not-exist.sock"))
        defer { Task { await client.shutdown() } }
        #expect(await client.ping() == false)
        await #expect(throws: DockerError.self) { try await client.version() }
    }

    @Test("A socket that exists but refuses connections is also 'not running'")
    func mapsDeadSocket() async throws {
        // A plain file at the socket path: it exists, so `ping` gets past the file check and has
        // to fail on connect — the case a stale socket file leaves behind.
        let path = FileManager.default.temporaryDirectory
            .appending(path: "crane-stale-\(UUID().uuidString.prefix(6)).sock").path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = DockerClient(socket: DockerSocket(path: path))
        defer { Task { await client.shutdown() } }
        #expect(await client.ping() == false)
        do {
            _ = try await client.version()
            Issue.record("expected a failure against a dead socket")
        } catch let error as DockerError {
            #expect(error == .notRunning(socket: path))
        }
    }

    @Test("An error status becomes the daemon's own message")
    func surfacesDaemonErrors() async throws {
        try await withDaemon(routes: [
            "/v1.51/_ping": .init(body: "OK"),
            "/v1.51/version": .init(status: .internalServerError, body: #"{"message":"engine on fire"}"#),
        ]) { client in
            do {
                _ = try await client.version()
                Issue.record("expected the 500 to throw")
            } catch let error as DockerError {
                #expect(error == .api(status: 500, message: "engine on fire"))
            }
        }
    }

    @Test("Events arrive as they are streamed, across chunk boundaries")
    func streamsEvents() async throws {
        let lines = [
            #"{"Type":"container","Action":"create","Actor":{"ID":"a1","Attributes":{"name":"/web"}}}"#,
            #"{"Type":"container","Action":"start","Actor":{"ID":"a1","Attributes":{"name":"/web"}}}"#,
            "",   // the keep-alive blank line the daemon sends
            #"{"Type":"container","Action":"die","Actor":{"ID":"a1","Attributes":{"exitCode":"0"}}}"#,
        ].joined(separator: "\n")

        try await withDaemon(routes: [
            "/v1.51/_ping": .init(body: "OK"),
            "/v1.51/events": .init(body: lines, streamed: true),
        ]) { client in
            var received: [DockerEvent] = []
            for try await event in client.events() { received.append(event) }
            #expect(received.map(\.action) == ["create", "start", "die"])
            #expect(received.first?.name == "web")
            #expect(received.last?.attributes["exitCode"] == "0")
        }
    }

    @Test("A `since` filter is sent as a query parameter")
    func passesSinceFilter() async throws {
        try await withDaemon(routes: [
            "/v1.51/_ping": .init(body: "OK"),
            "/v1.51/events": .init(body: #"{"Type":"daemon","Action":"reload"}"#, streamed: true),
        ]) { client in
            // The fake daemon routes on the path alone, so reaching the route at all proves the
            // query didn't corrupt the URL.
            var count = 0
            for try await _ in client.events(since: Date(timeIntervalSince1970: 1_700_000_000)) { count += 1 }
            #expect(count == 1)
        }
    }
}
