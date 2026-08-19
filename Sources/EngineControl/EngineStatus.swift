import Foundation

/// One binary's installed-versus-expected state.
public struct ComponentStatus: Sendable, Equatable, Identifiable {
    public let component: EngineComponent
    public let installed: String?
    public let expected: String

    public var id: String { component.rawValue }
    public var isInstalled: Bool { installed != nil }
    /// The pin is exact — socktainer links a specific runtime version — so "different" is
    /// "wrong", whether newer or older.
    public var matchesManifest: Bool { installed == expected }

    public init(component: EngineComponent, installed: String?, expected: String) {
        self.component = component
        self.installed = installed
        self.expected = expected
    }
}

/// A fix the Engine pane can perform with one button.
public enum RepairAction: Sendable, Equatable {
    case install(EngineComponent)
    case startRuntime
    case startDaemon
    case installContext
}

/// A single line in the Engine health list.
public struct Diagnostic: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable {
        /// Nothing to do.
        case ok
        /// Works, but not as intended — the user's own shell may point elsewhere.
        case warning
        /// The stack can't serve containers until this is fixed.
        case blocking
    }

    public let id: String
    public let title: String
    public let detail: String
    public let severity: Severity
    public let repair: RepairAction?

    public init(id: String, title: String, detail: String, severity: Severity, repair: RepairAction?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.repair = repair
    }
}

/// Everything Crane knows about the stack at one instant.
///
/// The `diagnostics` list is derived purely from these fields, so the panel's contents — and the
/// rule for what counts as "ready" — are tested without touching a disk or a socket.
public struct EngineStatus: Sendable, Equatable {
    public let components: [ComponentStatus]
    public let runtimeRunning: Bool
    public let daemonRunning: Bool
    public let socketPresent: Bool
    public let contextInstalled: Bool
    /// The Docker context the user's shell would use, or a `DOCKER_HOST=…` marker when the
    /// environment overrides contexts entirely.
    public let contextCurrent: String?
    /// A `docker` on PATH that is not Crane's, if any.
    public let foreignDockerPath: String?

    public init(components: [ComponentStatus], runtimeRunning: Bool, daemonRunning: Bool,
                socketPresent: Bool, contextInstalled: Bool, contextCurrent: String?,
                foreignDockerPath: String? = nil) {
        self.components = components
        self.runtimeRunning = runtimeRunning
        self.daemonRunning = daemonRunning
        self.socketPresent = socketPresent
        self.contextInstalled = contextInstalled
        self.contextCurrent = contextCurrent
        self.foreignDockerPath = foreignDockerPath
    }

    /// Nothing *engine* is installed yet — the app should onboard rather than show an empty dashboard.
    /// A leftover Docker CLI does not count; the GUI talks to the socket.
    public var isFresh: Bool {
        components.filter(\.component.isEngine).allSatisfy { !$0.isInstalled }
    }

    /// The engine can serve containers right now.
    public var isReady: Bool { !diagnostics.contains { $0.severity == .blocking } }

    public var isContextCurrent: Bool { contextCurrent == DockerContext.name }

    public var isDockerHostOverridden: Bool { contextCurrent?.hasPrefix("DOCKER_HOST=") == true }

    public var cliPackBlocked: Bool { foreignDockerPath != nil }

    /// Pinned Docker CLI and Compose both present under Crane's layout.
    public var cliPackInstalled: Bool {
        guard let docker = components.first(where: { $0.component == .docker }),
              let compose = components.first(where: { $0.component == .compose }) else { return false }
        return docker.matchesManifest && compose.matchesManifest
    }

    public var diagnostics: [Diagnostic] {
        var checks: [Diagnostic] = components.filter(\.component.isEngine).map(Self.diagnostic(for:))
        checks.append(runtimeCheck)
        checks.append(daemonCheck)
        if !contextInstalled {
            checks.append(contextMissingCheck)
        }
        return checks
    }

    private static func diagnostic(for status: ComponentStatus) -> Diagnostic {
        let component = status.component
        switch status.installed {
        case .none:
            return Diagnostic(id: component.rawValue, title: component.displayName,
                              detail: "Not installed. \(component.purpose)",
                              severity: .blocking, repair: .install(component))
        case let .some(version) where version != status.expected:
            return Diagnostic(id: component.rawValue, title: component.displayName,
                              detail: "Version \(version) is installed; this build of Crane is tested "
                                  + "against \(status.expected). The runtime and socktainer are pinned to "
                                  + "each other, so mixed versions fail in confusing ways.",
                              severity: .warning, repair: .install(component))
        case let .some(version):
            return Diagnostic(id: component.rawValue, title: component.displayName,
                              detail: version, severity: .ok, repair: nil)
        }
    }

    private var runtimeCheck: Diagnostic {
        Diagnostic(id: "runtime-service", title: "Container service",
                   detail: runtimeRunning ? "Running." : "Stopped — no container can start.",
                   severity: runtimeRunning ? .ok : .blocking,
                   repair: runtimeRunning ? nil : .startRuntime)
    }

    private var daemonCheck: Diagnostic {
        // Both halves must hold: launchd can report the job alive a moment before the socket
        // appears, and a stale socket file can outlive the process.
        let up = daemonRunning && socketPresent
        let detail: String
        if up {
            detail = "Listening. Docker-compatible tools can connect."
        } else if daemonRunning {
            detail = "Starting — the socket isn't there yet."
        } else {
            detail = "Not running. `docker`, Testcontainers and Dev Containers have nothing to talk to."
        }
        return Diagnostic(id: "daemon", title: "Docker API", detail: detail,
                          severity: up ? .ok : .blocking, repair: up ? nil : .startDaemon)
    }

    private var contextMissingCheck: Diagnostic {
        Diagnostic(id: "context", title: "Docker context",
                   detail: "Not registered — `docker` in your shell won't find this engine.",
                   severity: .warning, repair: .installContext)
    }
}
