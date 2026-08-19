import Foundation

    /// The four artifacts Crane can install: two for the engine, two for the optional CLI pack.
    /// Everything else on the machine is the user's business.
public enum EngineComponent: String, Sendable, CaseIterable, Identifiable, Codable {
    /// Apple's `container` — the runtime that actually boots the VMs.
    case runtime
    /// The Docker-compatible daemon that gives the ecosystem a socket to talk to.
    case socktainer
    /// The official `docker` CLI, so `docker …` is the real thing and not an imitation.
    case docker
    /// The `compose` CLI plugin, installed where the Docker CLI looks for plugins.
    case compose

    public var id: String { rawValue }

    /// True for the pieces the engine cannot run without. Docker CLI and Compose are optional.
    public var isEngine: Bool {
        switch self {
        case .runtime, .socktainer: return true
        case .docker, .compose: return false
        }
    }

    public var displayName: String {
        switch self {
        case .runtime: return "Apple container"
        case .socktainer: return "socktainer"
        case .docker: return "Docker CLI"
        case .compose: return "Docker Compose"
        }
    }

    public var purpose: String {
        switch self {
        case .runtime: return "Runs the Linux VMs behind every container."
        case .socktainer: return "Serves the Docker API that tools connect to."
        case .docker: return "The docker command itself."
        case .compose: return "Brings multi-service projects up."
        }
    }

    /// Arguments that make the binary print its version and exit.
    var versionArguments: [String] {
        switch self {
        case .runtime: return ["--version"]
        case .socktainer: return ["--version"]
        case .docker: return ["--version"]
        case .compose: return ["version", "--short"]
        }
    }
}

/// Where Crane keeps the stack on disk.
///
/// Everything lives under Application Support so installing needs no admin rights, with a
/// stable `bin/` in front of the versioned directories — that indirection is what lets an
/// upgrade be atomic and a rollback be one rewritten launcher.
public struct StackLayout: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Crane", directoryHint: .isDirectory)
    }

    public var versionsDirectory: URL { root.appending(path: "stack", directoryHint: .isDirectory) }
    public var binDirectory: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    public var logsDirectory: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var downloadsDirectory: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }

    /// The directory a specific version is unpacked into.
    public func directory(for artifact: Artifact) -> URL {
        versionsDirectory
            .appending(path: artifact.component.rawValue, directoryHint: .isDirectory)
            .appending(path: artifact.version, directoryHint: .isDirectory)
    }

    /// The executable inside a version directory. Apple's package keeps its helpers next to the
    /// binary in `bin/`, so its install root is the version directory itself.
    public func executable(for artifact: Artifact) -> URL {
        switch artifact.layout {
        case .applePackage:
            return directory(for: artifact).appending(path: "bin/container", directoryHint: .notDirectory)
        case let .executable(name), let .tarball(_, name):
            return directory(for: artifact).appending(path: name, directoryHint: .notDirectory)
        }
    }

    /// The stable path the launch agents and the app invoke (a `LauncherScript`).
    public func link(for component: EngineComponent) -> URL {
        let name: String
        switch component {
        case .runtime: name = "container"
        case .socktainer: name = "socktainer"
        case .docker: name = "docker"
        case .compose: name = "docker-compose"
        }
        return binDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Where the Docker CLI discovers its plugins; `compose` has to be here to be `docker compose`.
    public var cliPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".docker/cli-plugins", directoryHint: .isDirectory)
    }
}
