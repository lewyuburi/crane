import DockerAPI
import EngineControl
import Foundation
import Observation

/// The app's view of the engine: what state the stack is in, and the few actions that change it.
///
/// Everything the UI needs about the stack goes through here, so onboarding and the Engine pane
/// can never disagree about whether the engine is ready.
@MainActor
@Observable
public final class EngineModel {
    /// Where the app should take the user right now.
    public enum Phase: Equatable, Sendable {
        /// Still looking at the machine.
        case checking
        /// Nothing installed — show onboarding, not an empty dashboard.
        case needsSetup
        /// Installing or repairing.
        case working
        /// The engine serves containers.
        case ready
        /// Installed but not usable; the diagnostics say why.
        case needsAttention

        /// Where a given stack state lands. Pure, so "what does the user see" is a tested rule
        /// and not something scattered across view conditionals.
        public init(_ status: EngineStatus) {
            if status.isFresh {
                self = .needsSetup
            } else if status.isReady {
                self = .ready
            } else {
                self = .needsAttention
            }
        }
    }

    public private(set) var phase: Phase = .checking
    public private(set) var status: EngineStatus?
    /// Live install progress, keyed by component, while `phase == .working` or a CLI pack download.
    public private(set) var progress: [EngineComponent: StackInstaller.Progress] = [:]
    /// True while the optional CLI pack is downloading — the engine stays `.ready`.
    public private(set) var cliBusy = false
    /// Set when an action fails; the UI shows it and clears it.
    public var failure: String?

    public let engine: Engine
    public let client: DockerClient
    /// The engine's contents. Lives here so the feed has one place to deliver events to.
    public let workspace: WorkspaceStore
    private let feed: EventFeed
    private var feedTask: Task<Void, Never>?

    public init(engine: Engine = Engine(), client: DockerClient? = nil) {
        self.engine = engine
        let client = client ?? DockerClient(socket: DockerSocket(path: engine.socketPath))
        self.client = client
        self.workspace = WorkspaceStore(client: client)
        self.feed = EventFeed(client: client)
    }

    public var diagnostics: [Diagnostic] { status?.diagnostics ?? [] }

    /// Ready engine, no Crane CLI pack, nothing foreign on PATH — TipKit may offer the pack.
    public var shouldOfferCLITip: Bool {
        phase == .ready
            && status?.cliPackInstalled == false
            && status?.cliPackBlocked == false
    }

    /// Re-reads the stack's state. Cheap; safe to call whenever a window appears.
    public func refresh() async {
        let status = await engine.status()
        self.status = status
        phase = Phase(status)
    }

    /// Installs the engine. Optionally continues with the CLI pack when the checkbox was on.
    public func provision(includeCLI: Bool = false) async {
        await perform { engine, report in
            try await engine.provision(onProgress: report)
        }
        if includeCLI, failure == nil {
            await provisionCLI()
        }
    }

    /// Downloads Docker CLI + Compose without leaving the workspace for onboarding.
    public func provisionCLI() async {
        if status?.cliPackBlocked == true, let path = status?.foreignDockerPath {
            failure = EngineError.cliPackBlocked(path).errorDescription
            return
        }
        failure = nil
        cliBusy = true
        progress = [:]
        let report: @Sendable (StackInstaller.Progress) -> Void = { [weak self] update in
            Task { @MainActor in self?.progress[update.component] = update }
        }
        do {
            try await engine.provisionCLI(onProgress: report)
        } catch {
            failure = error.localizedDescription
        }
        progress = [:]
        cliBusy = false
        await refresh()
    }

    public func setUseCraneAsEngine(_ enabled: Bool) async {
        do {
            try await engine.setUseCraneAsEngine(enabled)
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
    }

    public func repair(_ action: RepairAction) async {
        await perform { engine, report in
            try await engine.repair(action, onProgress: report)
        }
    }

    /// Stops socktainer and the container apiserver without uninstalling Crane's stack.
    public func stopEngine() async {
        await perform { engine, _ in
            try await engine.stop()
        }
    }

    /// Subscribes to the daemon's event stream. Held for the app's lifetime: this is what makes
    /// the UI react in milliseconds instead of on a timer.
    public func startWatching() {
        guard feedTask == nil else { return }
        feedTask = Task { [feed, workspace] in
            for await signal in await feed.signals() {
                switch signal {
                case .connected:
                    if phase == .needsAttention { await refresh() }
                case let .disconnected(reason):
                    // The feed retries on its own; reflect reality without nagging.
                    if phase == .ready { phase = .needsAttention }
                    if let reason { failure = reason }
                    await refresh()
                case .resync:
                    // Anything could have changed while the feed was down.
                    await workspace.reloadAll()
                case let .event(event):
                    workspace.handle(event)
                }
            }
        }
    }

    public func stopWatching() async {
        feedTask?.cancel()
        feedTask = nil
        await feed.stop()
    }

    /// Runs a mutating engine action with the shared progress/failure handling.
    private func perform(_ body: @escaping @Sendable (Engine, @Sendable @escaping (StackInstaller.Progress) -> Void) async throws -> Void) async {
        phase = .working
        failure = nil
        progress = [:]
        let report: @Sendable (StackInstaller.Progress) -> Void = { [weak self] update in
            Task { @MainActor in self?.progress[update.component] = update }
        }
        do {
            try await body(engine, report)
        } catch {
            failure = error.localizedDescription
        }
        progress = [:]
        await refresh()
    }

    /// Snapshot and canvas seeding. Does not talk to a live engine.
    public func seedPreview(status: EngineStatus, phase: Phase) {
        self.status = status
        self.phase = phase
        previewLocked = true
    }

    /// When true, EngineView must not `refresh()` over seeded preview state.
    public private(set) var previewLocked = false
}
