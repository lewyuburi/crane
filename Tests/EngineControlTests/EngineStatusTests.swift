import Foundation
import Testing

@testable import EngineControl

@Suite("Diagnostics derivation")
struct EngineStatusTests {
    private func status(
        runtime: String? = "1.2.0", socktainer: String? = "1.2.1",
        docker: String? = "29.7.2", compose: String? = "5.4.0",
        runtimeRunning: Bool = true, daemonRunning: Bool = true, socketPresent: Bool = true,
        contextInstalled: Bool = true, contextCurrent: String? = "crane"
    ) -> EngineStatus {
        let manifest = StackManifest.current
        return EngineStatus(
            components: [
                ComponentStatus(component: .runtime, installed: runtime, expected: manifest.runtime.version),
                ComponentStatus(component: .socktainer, installed: socktainer, expected: manifest.socktainer.version),
                ComponentStatus(component: .docker, installed: docker, expected: manifest.docker.version),
                ComponentStatus(component: .compose, installed: compose, expected: manifest.compose.version),
            ],
            runtimeRunning: runtimeRunning, daemonRunning: daemonRunning, socketPresent: socketPresent,
            contextInstalled: contextInstalled, contextCurrent: contextCurrent)
    }

    private func diagnostic(_ status: EngineStatus, _ id: String) -> Diagnostic {
        status.diagnostics.first { $0.id == id }!
    }

    @Test("A fully provisioned stack reports ready with no repairs offered")
    func healthyStack() {
        let healthy = status()
        #expect(healthy.isReady)
        #expect(!healthy.isFresh)
        #expect(healthy.diagnostics.allSatisfy { $0.severity == .ok && $0.repair == nil })
    }

    @Test("A machine with nothing installed is fresh, not broken")
    func freshMachine() {
        let fresh = status(runtime: nil, socktainer: nil, docker: nil, compose: nil,
                           runtimeRunning: false, daemonRunning: false, socketPresent: false,
                           contextInstalled: false, contextCurrent: nil)
        #expect(fresh.isFresh)
        #expect(!fresh.isReady)
        #expect(diagnostic(fresh, "runtime").repair == .install(.runtime))
    }

    @Test("Missing runtime or daemon blocks; missing CLIs only warn")
    func severityByComponent() {
        let noRuntime = status(runtime: nil)
        #expect(diagnostic(noRuntime, "runtime").severity == .blocking)
        #expect(!noRuntime.isReady)

        let noDocker = status(docker: nil, compose: nil)
        #expect(diagnostic(noDocker, "docker").severity == .warning)
        #expect(diagnostic(noDocker, "compose").severity == .warning)
        #expect(noDocker.isReady, "the app talks to the socket, so a missing CLI can't block it")
    }

    @Test("A version off the pinned pair warns and offers to reinstall")
    func versionDrift() {
        let drifted = status(socktainer: "1.1.0")
        let check = diagnostic(drifted, "socktainer")
        #expect(check.severity == .warning)
        #expect(check.repair == .install(.socktainer))
        #expect(check.detail.contains("1.1.0") && check.detail.contains("1.2.1"))
        #expect(drifted.isReady, "an off-version binary still runs — it's a warning, not a wall")
    }

    @Test("The daemon isn't healthy until its socket exists")
    func daemonNeedsSocket() {
        let starting = status(socketPresent: false)
        #expect(diagnostic(starting, "daemon").severity == .blocking)
        #expect(diagnostic(starting, "daemon").detail.contains("isn't there yet"))
        #expect(diagnostic(starting, "daemon").repair == .startDaemon)

        let down = status(daemonRunning: false, socketPresent: false)
        #expect(diagnostic(down, "daemon").detail.contains("Testcontainers"))
    }

    @Test("A stopped container service blocks and offers to start")
    func stoppedRuntimeService() {
        let stopped = status(runtimeRunning: false)
        #expect(diagnostic(stopped, "runtime-service").severity == .blocking)
        #expect(diagnostic(stopped, "runtime-service").repair == .startRuntime)
    }

    @Test("Another selected context warns and offers to switch")
    func otherContextSelected() {
        let other = status(contextCurrent: "colima")
        let check = diagnostic(other, "context")
        #expect(check.severity == .warning)
        #expect(check.repair == .useContext)
        #expect(check.detail.contains("colima"))
    }

    @Test("DOCKER_HOST overrides contexts, so no switch button is offered")
    func dockerHostOverride() {
        let overridden = status(contextCurrent: "DOCKER_HOST=tcp://10.0.0.2:2375")
        let check = diagnostic(overridden, "context")
        #expect(check.severity == .warning)
        #expect(check.repair == nil)
        #expect(check.detail.contains("overrides"))
    }

    @Test("An unregistered context warns and offers to register")
    func missingContext() {
        let check = diagnostic(status(contextInstalled: false, contextCurrent: nil), "context")
        #expect(check.repair == .installContext)
    }
}
