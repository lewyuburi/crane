import AppleContainer
import Foundation

/// Owns the container stack: what's installed, what's running, and how to fix either.
///
/// This is the only place that knows the stack is runtime + socktainer (engine) plus an
/// optional Docker CLI pack, two launch agents, and a Docker context.
/// Everything above it asks two questions — "is it ready?" and "make it ready" — which is what
/// keeps onboarding, the Engine pane and the CLI from each growing their own version of
/// the truth.
public actor Engine {
    public static let runtimeAgentLabel = "dev.crane.runtime"
    public static let daemonAgentLabel = "dev.crane.socktainer"

    public let manifest: StackManifest
    public let layout: StackLayout
    private let installer: StackInstaller

    public init(manifest: StackManifest = .current, layout: StackLayout = StackLayout()) {
        self.manifest = manifest
        self.layout = layout
        self.installer = StackInstaller(layout: layout)
    }

    public nonisolated var runtime: ContainerRuntime {
        ContainerRuntime(executable: layout.link(for: .runtime).path)
    }

    public nonisolated var context: DockerContext {
        DockerContext(socketPath: socketPath)
    }

    /// socktainer binds this path; it is not configurable there, so Crane follows it.
    public nonisolated var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".socktainer/container.sock", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    // MARK: - Status

    /// Inspects every part of the stack. Cheap enough to run on demand (a few `--version` calls
    /// and one `launchctl print`), and never mutates anything.
    public func status() async -> EngineStatus {
        var components: [ComponentStatus] = []
        for component in EngineComponent.allCases {
            let expected = manifest.artifact(for: component).version
            let installed = await installer.installedVersion(of: component)
            components.append(ComponentStatus(component: component, installed: installed, expected: expected))
        }
        async let runtimeUp = runtime.isSystemRunning()
        async let daemonUp = LaunchControl.isRunning(label: Self.daemonAgentLabel)
        let socketPresent = FileManager.default.fileExists(atPath: socketPath)
        return EngineStatus(
            components: components,
            runtimeRunning: await runtimeUp,
            daemonRunning: await daemonUp,
            socketPresent: socketPresent,
            contextInstalled: context.isInstalled,
            contextCurrent: context.currentContext,
            foreignDockerPath: DockerLocator.foreignPath(craneBin: layout.binDirectory)
        )
    }

    // MARK: - Installation

    /// Brings the engine to the blessed state: runtime, socktainer, launch agents, and a
    /// registered `crane` context. Does not install the Docker CLI pack.
    ///
    /// Safe to re-run. Onboarding and "Repair everything" are the same call. If a foreign
    /// `docker` is on PATH, the context is registered but not selected — stealing the user's
    /// current engine is a setting, not a side effect of setup.
    public func provision(onProgress: @Sendable @escaping (StackInstaller.Progress) -> Void = { _ in }) async throws {
        for artifact in manifest.engineArtifacts {
            try await installer.install(artifact, onProgress: onProgress)
        }
        try await installAgents()
        try context.install()
        if DockerLocator.foreignPath(craneBin: layout.binDirectory) == nil {
            rememberPreviousContext()
            try context.makeCurrent()
        }
    }

    /// Downloads the pinned Docker CLI and Compose, puts Crane's `bin/` on PATH, and selects
    /// the `crane` context. Refuses to run when a foreign `docker` is already on PATH.
    public func provisionCLI(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        onProgress: @Sendable @escaping (StackInstaller.Progress) -> Void = { _ in }
    ) async throws {
        if let foreign = DockerLocator.foreignPath(craneBin: layout.binDirectory) {
            throw EngineError.cliPackBlocked(foreign)
        }
        for artifact in manifest.cliArtifacts {
            try await installer.install(artifact, onProgress: onProgress)
        }
        try CLIPathSnippet.install(home: home, binDirectory: layout.binDirectory)
        rememberPreviousContext()
        try context.makeCurrent()
    }

    /// Selects or restores the Docker context. The Engine pane's switch calls this.
    public func setUseCraneAsEngine(_ enabled: Bool) throws {
        if enabled {
            rememberPreviousContext()
            try context.makeCurrent()
        } else {
            try restorePreviousContext()
        }
    }

    /// Puts the Docker CLI back on whatever context it used before Crane took over.
    ///
    /// Selecting a context is the one thing provisioning changes outside Crane's own folders, so
    /// it has to be undoable — a user trying Crane next to another runtime must be able to go back.
    public func restorePreviousContext() throws {
        try context.resign(to: previousContext)
        try? FileManager.default.removeItem(at: previousContextFile)
    }

    /// The context that was selected before Crane's, if any.
    public var previousContext: String? {
        guard let saved = try? String(contentsOf: previousContextFile, encoding: .utf8) else { return nil }
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var previousContextFile: URL {
        layout.root.appending(path: "previous-docker-context", directoryHint: .notDirectory)
    }

    /// Records the outgoing selection once — re-provisioning must not overwrite it with "crane".
    private func rememberPreviousContext() {
        let current = context.currentContext
        guard current != DockerContext.name,
              !(current?.hasPrefix("DOCKER_HOST=") ?? false),
              !FileManager.default.fileExists(atPath: previousContextFile.path) else { return }
        try? FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try? Data((current ?? "default").utf8).write(to: previousContextFile, options: .atomic)
    }

    /// Writes and loads both agents. The runtime one is a one-shot that starts the apiserver at
    /// login; socktainer's is supervised, so launchd brings it back if it exits.
    public func installAgents() async throws {
        try FileManager.default.createDirectory(at: layout.logsDirectory, withIntermediateDirectories: true)
        try await LaunchControl.install(LaunchAgent(
            label: Self.runtimeAgentLabel,
            program: [layout.link(for: .runtime).path, "system", "start", "--enable-kernel-install"],
            runAtLoad: true,
            keepAlive: false,
            standardOutPath: logPath("runtime.log"),
            standardErrorPath: logPath("runtime.log")
        ))
        try await LaunchControl.install(LaunchAgent(
            label: Self.daemonAgentLabel,
            // Crane owns the Docker context, so socktainer must not write its own.
            // Skip socktainer's exact-version gate: Apple's `container` at /usr/local
            // (or a newer patch) is often already the live XPC apiserver, and
            // `container system start` is a no-op when that service is up. socktainer
            // 1.2.1 then refuses to start against 1.2.2 even though the API works.
            program: [layout.link(for: .socktainer).path, "--no-docker-context", "--no-check-compatibility"],
            runAtLoad: true,
            keepAlive: true,
            standardOutPath: logPath("socktainer.log"),
            standardErrorPath: logPath("socktainer.log")
        ))
    }

    // MARK: - Repairs

    /// Performs one health-row fix. Each case is small and idempotent so the Engine pane can
    /// offer it as a single button without a confirmation dance.
    public func repair(_ action: RepairAction,
                       onProgress: @Sendable @escaping (StackInstaller.Progress) -> Void = { _ in }) async throws {
        switch action {
        case let .install(component):
            try await installer.install(manifest.artifact(for: component), onProgress: onProgress)
        case .startRuntime:
            try await runtime.startSystem()
        case .startDaemon:
            if await LaunchControl.isRunning(label: Self.daemonAgentLabel) {
                try await LaunchControl.restart(label: Self.daemonAgentLabel)
            } else {
                try await installAgents()
            }
        case .installContext:
            try context.install()
        }
    }

    private func logPath(_ name: String) -> String {
        layout.logsDirectory.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
    }
}
