import EngineControl
import Foundation
import Testing

@testable import CraneCore

@Suite("What the window shows")
struct PhaseTests {
    private func status(installed: Bool, running: Bool) -> EngineStatus {
        let manifest = StackManifest.current
        return EngineStatus(
            components: EngineComponent.allCases.map {
                ComponentStatus(component: $0,
                                installed: installed ? manifest.artifact(for: $0).version : nil,
                                expected: manifest.artifact(for: $0).version)
            },
            runtimeRunning: running, daemonRunning: running, socketPresent: running,
            contextInstalled: installed, contextCurrent: installed ? "crane" : nil)
    }

    @Test("An untouched Mac gets onboarding, not an error screen")
    func freshMachineOnboards() {
        #expect(EngineModel.Phase(status(installed: false, running: false)) == .needsSetup)
    }

    @Test("A provisioned, running stack is ready")
    func provisionedIsReady() {
        #expect(EngineModel.Phase(status(installed: true, running: true)) == .ready)
    }

    @Test("Installed but stopped means attention, not setup")
    func installedButStopped() {
        #expect(EngineModel.Phase(status(installed: true, running: false)) == .needsAttention)
    }
}
