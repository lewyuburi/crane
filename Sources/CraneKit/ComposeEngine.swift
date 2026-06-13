import Foundation

/// A progress event from a Compose operation. Sendable so it can cross from the engine's
/// background task to whatever consumes it — SwiftUI on the main actor, or a CLI printing to a TTY.
public enum ComposeEvent: Sendable {
    case log(String)        // a progress line
    case failure(String)    // a service failed to start (message)
}

/// UI-agnostic Compose orchestration: brings projects up by driving a `ContainerControlling`.
/// It owns the whole `docker compose up` semantics (network/volumes, recreate, stack host-wiring,
/// flaky-DNS retries) and reports progress as an `AsyncStream<ComposeEvent>`. Shared by the
/// SwiftUI app (via AppModel) and, later, a docker-compose-compatible CLI — neither needs the
/// other's runtime.
public struct ComposeEngine: Sendable {
    public let cli: any ContainerControlling
    /// Delay between stack restart attempts. Injectable so tests don't wait on the real backoff.
    public var retryDelay: Duration = .seconds(4)

    public init(cli: any ContainerControlling, retryDelay: Duration = .seconds(4)) {
        self.cli = cli
        self.retryDelay = retryDelay
    }

    /// `docker compose up` for a whole project.
    public func up(_ project: ComposeProject) -> AsyncStream<ComposeEvent> {
        stream { emit in await performUp(project, emit: emit) }
    }

    /// `docker compose up <service>` for a single service.
    public func up(service: ComposeService, in project: ComposeProject) -> AsyncStream<ComposeEvent> {
        stream { emit in
            if project.isStack { await announceStack(project, emit) }
            let network = project.isStack ? "default" : project.name
            emit(.log("▸ Network \(network)"))
            await cli.createNetworkIfNeeded(network)
            await startService(service, project: project, emit: emit)
            emit(.log("Done."))
        }
    }

    /// `docker compose down`: stop and remove every container in the project.
    public func down(_ projectName: String) async {
        let ids = ((try? await cli.listContainers()) ?? [])
            .filter { $0.composeProject == projectName }.map(\.id).sorted()
        for id in ids {
            try? await cli.stop(id: id)
            try? await cli.delete(id: id)
        }
    }

    // MARK: - Implementation

    private func performUp(_ project: ComposeProject, emit: (ComposeEvent) -> Void) async {
        if project.isStack { await announceStack(project, emit) }
        let network = project.isStack ? "default" : project.name
        emit(.log("▸ Network \(network)"))
        await cli.createNetworkIfNeeded(network)
        for vol in project.namedVolumes {
            emit(.log("▸ Volume \(vol)"))
            await cli.createVolumeIfNeeded(vol)
        }
        for service in project.startupOrder {
            await startService(service, project: project, emit: emit)
        }
        await wireHosts(project, emit)
        if project.isStack { await retryFailed(project, emit) }
        emit(.log("Done."))
    }

    /// Recreate-and-run one service: remove any container with its name, pre-create bind dirs,
    /// build if needed, then run detached.
    private func startService(_ service: ComposeService, project: ComposeProject, emit: (ComposeEvent) -> Void) async {
        emit(.log("▸ \(service.name): starting…"))
        let name = service.containerName(project: project.name)
        do {
            try? await cli.stop(id: name)
            try? await cli.delete(id: name)
            for path in service.hostBindPaths where !FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            if let build = service.build, let tag = service.runImage(project: project.name) {
                emit(.log("  building \(tag)…"))
                try await cli.buildImage(build, tag: tag)
            }
            try await cli.runDetached(arguments: service.runArguments(project: project.name, stack: project.isStack))
            emit(.log("  ✓ \(name)"))
        } catch {
            emit(.failure(error.localizedDescription))
        }
    }

    /// EXPERIMENTAL multi-service stacks: warn when the internal DNS that lets services reach each
    /// other by name isn't configured. (Apple `container` 1.0.x: flaky, default-network-only.)
    private func announceStack(_ project: ComposeProject, _ emit: (ComposeEvent) -> Void) async {
        emit(.log("▸ Multi-service stack (experimental) — using the default network + internal DNS"))
        if await cli.configuredDNSDomain() == nil {
            emit(.log("  ⚠️ Internal DNS not configured — services may not resolve each other by name."))
            emit(.log("     Enable once (admin): sudo container system dns create crane"))
            emit(.log("     then add to ~/.config/container/config.toml:  [dns] domain = \"crane\"  and restart the service."))
        }
    }

    /// Belt-and-suspenders for stacks: inject `/etc/hosts` entries mapping each sibling's
    /// service/container name to its IP, helping already-running, lazy-connecting apps.
    private func wireHosts(_ project: ComposeProject, _ emit: (ComposeEvent) -> Void) async {
        let running = ((try? await cli.listContainers()) ?? [])
            .filter { $0.composeProject == project.name && $0.isRunning }
        let members = running.compactMap { c -> HostsWiring.Member? in
            guard let ip = c.addresses.first else { return nil }
            return HostsWiring.Member(containerID: c.id, service: c.composeService ?? c.id, ip: ip)
        }
        let byID = HostsWiring.entries(members: members)
        guard !byID.isEmpty else { return }
        emit(.log("▸ Wiring \(running.count) services for name resolution"))
        // Pass each "ip\thost" line as a positional argument ("$@"), never interpolated into the
        // script — so a hostile service name (e.g. one with quotes) is treated as data, not code.
        let script = #"for e in "$@"; do grep -qF "$e" /etc/hosts || printf '%s\n' "$e" >> /etc/hosts; done"#
        for c in running {
            guard let lines = byID[c.id] else { continue }
            _ = try? await cli.exec(id: c.id, command: ["sh", "-c", script, "sh"] + lines)
        }
    }

    /// Apple's internal DNS is flaky, so a dependent that checks its DB at boot can exit before DNS
    /// answers. We restart any exited stack container a few times; on restart it usually comes up.
    private func retryFailed(_ project: ComposeProject, _ emit: (ComposeEvent) -> Void) async {
        for attempt in 1...3 {
            let down = ((try? await cli.listContainers()) ?? [])
                .filter { $0.composeProject == project.name && !$0.isRunning }
            if down.isEmpty { return }
            emit(.log("  ↻ retry \(attempt): restarting \(down.map(\.id).joined(separator: ", "))"))
            for c in down { try? await cli.start(id: c.id) }
            try? await Task.sleep(for: retryDelay)
        }
    }

    /// Wraps a producing closure in an AsyncStream whose backing task is cancelled if abandoned.
    private func stream(_ body: @escaping @Sendable (@escaping (ComposeEvent) -> Void) async -> Void) -> AsyncStream<ComposeEvent> {
        AsyncStream { continuation in
            let task = Task {
                await body { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
