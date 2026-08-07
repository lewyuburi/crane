import Foundation
import Testing

@testable import DockerAPI

@Suite("Event decoding")
struct DockerEventTests {
    private func decode(_ json: String) throws -> DockerEvent {
        try JSONDecoder().decode(DockerEvent.self, from: Data(json.utf8))
    }

    @Test("Decodes a container start event")
    func decodesStart() throws {
        let event = try decode("""
        {"Type":"container","Action":"start","Actor":{"ID":"abc123",
        "Attributes":{"name":"/web","image":"nginx:alpine",
        "com.docker.compose.project":"shop"}},"scope":"local","time":1700000000,
        "timeNano":1700000000123456789}
        """)
        #expect(event.subject == .container)
        #expect(event.action == "start")
        #expect(event.id == "abc123")
        #expect(event.name == "web")
        #expect(event.composeProject == "shop")
        #expect(event.affectsContainerList)
        #expect(abs(event.time.timeIntervalSince1970 - 1_700_000_000.123) < 0.01)
    }

    @Test("An unknown subject decodes instead of breaking the stream")
    func tolerantSubject() throws {
        let event = try decode(#"{"Type":"swarm-thing","Action":"whatever","Actor":{"ID":"x"}}"#)
        #expect(event.subject == .unknown)
        #expect(!event.affectsContainerList)
    }

    @Test("Falls back to the legacy top-level id and whole-second time")
    func legacyShape() throws {
        let event = try decode(#"{"Type":"image","Action":"pull","id":"nginx:latest","time":1700000000}"#)
        #expect(event.id == "nginx:latest")
        #expect(event.time == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Health transitions are readable as a status")
    func healthStatus() throws {
        let healthy = try decode(#"{"Type":"container","Action":"health_status: healthy","Actor":{"ID":"a"}}"#)
        #expect(healthy.healthStatus == "healthy")
        #expect(healthy.affectsContainerList)
        let started = try decode(#"{"Type":"container","Action":"start","Actor":{"ID":"a"}}"#)
        #expect(started.healthStatus == nil)
    }

    @Test("Exec noise doesn't invalidate the container list")
    func ignoresExecNoise() throws {
        for action in ["exec_create: sh", "exec_start: sh -c ls", "exec_die", "resize"] {
            let event = try decode(#"{"Type":"container","Action":"\#(action)","Actor":{"ID":"a"}}"#)
            #expect(!event.affectsContainerList, "\(action) should not refresh the list")
        }
    }

    @Test("A daemon message body becomes the error text")
    func mapsAPIError() {
        let error = DockerError.from(status: 409, body: Data(#"{"message":"container already started"}"#.utf8))
        #expect(error == .api(status: 409, message: "container already started"))
        #expect(error.errorDescription == "container already started")
    }

    @Test("A non-JSON error body is still surfaced verbatim")
    func mapsPlainError() {
        let error = DockerError.from(status: 500, body: Data("boom\n".utf8))
        #expect(error == .api(status: 500, message: "boom"))
    }
}
