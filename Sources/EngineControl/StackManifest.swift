import Foundation

/// The set of binaries Crane installs and supervises, pinned as one blessed combination.
///
/// They are versioned together on purpose: socktainer links `apple/container` with an **exact**
/// version in its own `Package.swift`, so a mismatched pair fails in ways a user can't diagnose.
/// Bumping the stack means bumping this table, re-computing the digests, and testing the pair —
/// never letting a component drift on its own.
public struct StackManifest: Sendable, Equatable {
    public let runtime: Artifact
    public let socktainer: Artifact
    public let docker: Artifact
    public let compose: Artifact

    public var artifacts: [Artifact] { [runtime, socktainer, docker, compose] }

    public func artifact(for component: EngineComponent) -> Artifact {
        switch component {
        case .runtime: return runtime
        case .socktainer: return socktainer
        case .docker: return docker
        case .compose: return compose
        }
    }

    /// What Crane 2.0 ships against. Digests are SHA-256 of the exact published asset.
    public static let current = StackManifest(
        runtime: Artifact(
            component: .runtime,
            version: "1.2.0",
            url: "https://github.com/apple/container/releases/download/1.2.0/container-1.2.0-installer-signed.pkg",
            sha256: "d140d4076ff0593d6b4f7c58722717b2abe87d75452cfe0a203792ba7f48f07c",
            layout: .applePackage
        ),
        socktainer: Artifact(
            component: .socktainer,
            version: "1.2.1",
            url: "https://github.com/socktainer/socktainer/releases/download/v1.2.1/socktainer",
            sha256: "3304a62bc1c29402dc39a45a1dc74098904c9dea8267f7ad97fff1af022fac0b",
            layout: .executable(name: "socktainer")
        ),
        docker: Artifact(
            component: .docker,
            version: "29.7.2",
            url: "https://download.docker.com/mac/static/stable/aarch64/docker-29.7.2.tgz",
            sha256: "b8683ed19d1f06048a496f9b8429e2c71d0b088d475b7487c054ea3666c02a3c",
            layout: .tarball(binary: "docker/docker", name: "docker")
        ),
        compose: Artifact(
            component: .compose,
            version: "5.4.0",
            url: "https://github.com/docker/compose/releases/download/v5.4.0/docker-compose-darwin-aarch64",
            sha256: "bc3d1fd4c01e3af9b481fc5ea153ea7c006c77eb39be78e9af3e2e8ebecc0d61",
            layout: .executable(name: "docker-compose")
        )
    )

    public init(runtime: Artifact, socktainer: Artifact, docker: Artifact, compose: Artifact) {
        self.runtime = runtime
        self.socktainer = socktainer
        self.docker = docker
        self.compose = compose
    }
}

/// One downloadable piece of the stack.
public struct Artifact: Sendable, Equatable {
    /// How the download turns into an executable on disk.
    public enum Layout: Sendable, Equatable {
        /// Apple's signed `.pkg`, expanded (never installed) so no admin rights are needed.
        case applePackage
        /// A bare executable: chmod +x and done.
        case executable(name: String)
        /// A `.tar.gz` holding the binary at `binary`, installed as `name`.
        case tarball(binary: String, name: String)
    }

    public let component: EngineComponent
    public let version: String
    public let url: String
    /// Lowercase hex SHA-256 of the published asset. Nothing is installed without matching it:
    /// none of these publishers ship a signature Crane can verify on its own.
    public let sha256: String
    public let layout: Layout

    public init(component: EngineComponent, version: String, url: String, sha256: String, layout: Layout) {
        self.component = component
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.layout = layout
    }

    /// The executable's name once installed.
    public var executableName: String {
        switch layout {
        case .applePackage: return "container"
        case let .executable(name), let .tarball(_, name): return name
        }
    }
}
