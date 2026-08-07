import DockerAPI
import EngineControl
import Foundation
import Observation

/// The app's view of the engine: what state the stack is in, and the few actions that change it.
///
/// Everything the UI needs about the stack goes through here, so onboarding, the diagnostics
/// panel and the menu bar can never disagree about whether the engine is ready.
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
    /// Live install progress, keyed by component, while `phase == .working`.
    public private(set) var progress: [EngineComponent: StackInstaller.Progress] = [:]
    /// The daemon's own version report, once it answers.
    public private(set) var daemonVersion: DockerVersion?
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

    /// Re-reads the stack's state. Cheap; safe to call whenever a window appears.
    public func refresh() async {
        let status = await engine.status()
        self.status = status
        phase = Phase(status)
        if phase == .ready {
            daemonVersion = try? await client.version()
        }
    }

    /// Installs and wires up everything. This is both "get started" and "repair it all".
    public func provision() async {
        await perform { engine, report in
            try await engine.provision(onProgress: report)
        }
    }

    public func repair(_ action: RepairAction) async {
        await perform { engine, report in
            try await engine.repair(action, onProgress: report)
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
}
