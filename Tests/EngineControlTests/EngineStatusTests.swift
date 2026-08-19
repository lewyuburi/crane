import Foundation
import Testing

@testable import EngineControl

@Suite("Diagnostics derivation")
struct EngineStatusTests {
    private func status(
        runtime: String? = "1.2.0", socktainer: String? = "1.2.1",
        docker: String? = nil, compose: String? = nil,
        runtimeRunning: Bool = true, daemonRunning: Bool = true, socketPresent: Bool = true,
        contextInstalled: Bool = true, contextCurrent: String? = "crane",
        foreignDockerPath: String? = nil
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
            contextInstalled: contextInstalled, contextCurrent: contextCurrent,
            foreignDockerPath: foreignDockerPath)
    }

    private func diagnostic(_ status: EngineStatus, _ id: String) -> Diagnostic? {
        status.diagnostics.first { $0.id == id }
    }

    @Test("A running engine is ready without a Docker CLI pack")
    func healthyStack() {
        let healthy = status()
        #expect(healthy.isReady)
        #expect(!healthy.isFresh)
        #expect(!healthy.cliPackInstalled)
        #expect(healthy.diagnostics.allSatisfy { $0.severity == .ok && $0.repair == nil })
        #expect(diagnostic(healthy, "docker") == nil)
        #expect(diagnostic(healthy, "context") == nil)
    }

    @Test("A machine with nothing engine-related installed is fresh, not broken")
    func freshMachine() {
        let fresh = status(runtime: nil, socktainer: nil, docker: nil, compose: nil,
                           runtimeRunning: false, daemonRunning: false, socketPresent: false,
                           contextInstalled: false, contextCurrent: nil)
        #expect(fresh.isFresh)
        #expect(!fresh.isReady)
        #expect(diagnostic(fresh, "runtime")?.repair == .install(.runtime))
    }

    @Test("A leftover Docker CLI does not keep a bare machine out of onboarding")
    func leftoverCLIIsStillFresh() {
        let leftover = status(runtime: nil, socktainer: nil, docker: "29.7.2", compose: "5.4.0",
                              runtimeRunning: false, daemonRunning: false, socketPresent: false,
                              contextInstalled: false, contextCurrent: nil)
        #expect(leftover.isFresh)
    }

    @Test("Missing runtime blocks; missing CLIs are not diagnostics")
    func severityByComponent() {
        let noRuntime = status(runtime: nil)
        #expect(diagnostic(noRuntime, "runtime")?.severity == .blocking)
        #expect(!noRuntime.isReady)

        let noDocker = status(docker: nil, compose: nil)
        #expect(diagnostic(noDocker, "docker") == nil)
        #expect(diagnostic(noDocker, "compose") == nil)
        #expect(noDocker.isReady)
    }

    @Test("The CLI pack is installed only when both pinned binaries match")
    func cliPackInstalled() {
        #expect(!status(docker: "29.7.2").cliPackInstalled)
        #expect(status(docker: "29.7.2", compose: "5.4.0").cliPackInstalled)
        #expect(status(docker: "29.7.2", compose: "5.4.0", foreignDockerPath: "/usr/bin/docker").cliPackBlocked)
    }

    @Test("A version off the pinned pair warns and offers to reinstall")
    func versionDrift() {
        let drifted = status(socktainer: "1.1.0")
        let check = diagnostic(drifted, "socktainer")
        #expect(check?.severity == .warning)
        #expect(check?.repair == .install(.socktainer))
        #expect(check?.detail.contains("1.1.0") == true && check?.detail.contains("1.2.1") == true)
        #expect(drifted.isReady, "an off-version binary still runs — it's a warning, not a wall")
    }

    @Test("The daemon isn't healthy until its socket exists")
    func daemonNeedsSocket() {
        let starting = status(socketPresent: false)
        #expect(diagnostic(starting, "daemon")?.severity == .blocking)
        #expect(diagnostic(starting, "daemon")?.detail.contains("isn't there yet") == true)
        #expect(diagnostic(starting, "daemon")?.repair == .startDaemon)

        let down = status(daemonRunning: false, socketPresent: false)
        #expect(diagnostic(down, "daemon")?.detail.contains("Testcontainers") == true)
    }

    @Test("A stopped container service blocks and offers to start")
    func stoppedRuntimeService() {
        let stopped = status(runtimeRunning: false)
        #expect(diagnostic(stopped, "runtime-service")?.severity == .blocking)
        #expect(diagnostic(stopped, "runtime-service")?.repair == .startRuntime)
    }

    @Test("Another selected context is not a health warning — the Engine toggle handles it")
    func otherContextSelected() {
        let other = status(contextCurrent: "colima")
        #expect(other.isReady)
        #expect(diagnostic(other, "context") == nil)
        #expect(!other.isContextCurrent)
    }

    @Test("DOCKER_HOST is surfaced as an override, not a silent switch")
    func dockerHostOverride() {
        let overridden = status(contextCurrent: "DOCKER_HOST=tcp://10.0.0.2:2375")
        #expect(overridden.isDockerHostOverridden)
        #expect(diagnostic(overridden, "context") == nil)
    }

    @Test("An unregistered context warns and offers to register")
    func missingContext() {
        #expect(diagnostic(status(contextInstalled: false, contextCurrent: nil), "context")?.repair == .installContext)
    }
}
