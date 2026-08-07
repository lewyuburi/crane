import DockerAPI
import Foundation
import Observation

/// Everything the app displays about the engine's contents, kept current by events.
///
/// The flow is: one snapshot at launch, then `/events` drives the reducer. Fetches only happen
/// when an event can't describe the new shape by itself, and they're coalesced — bringing a
/// twelve-service project up fires dozens of events but costs one round-trip.
@MainActor
@Observable
public final class WorkspaceStore {
    public private(set) var catalog = ContainerCatalog()
    public private(set) var images: [ImageSummary] = []
    public private(set) var volumes: [VolumeSummary] = []
    public private(set) var networks: [NetworkSummary] = []
    /// True once the first snapshot has landed, so views can tell "empty" from "not loaded yet".
    public private(set) var isLoaded = false
    /// Containers with an action in flight, so their buttons can show progress.
    public private(set) var busy: Set<String> = []
    public var failure: String?

    public var containers: [Container] { catalog.containers }
    public var grouping: ContainerGrouping { catalog.grouping }

    private let client: DockerClient
    /// How long events are gathered before a refetch. Long enough to collapse a burst, short
    /// enough that nobody perceives it.
    private let coalesceWindow: Duration
    private var pendingContainers: Set<String> = []
    private var pendingLists: Set<ListKind> = []
    private var flush: Task<Void, Never>?

    private enum ListKind: Hashable { case containers, images, volumes, networks }

    public init(client: DockerClient, coalesceWindow: Duration = .milliseconds(60)) {
        self.client = client
        self.coalesceWindow = coalesceWindow
    }

    // MARK: - Loading

    /// Reloads everything. Called at launch and whenever the event feed reconnects, since events
    /// missed while disconnected would otherwise leave the list quietly wrong.
    public func reloadAll() async {
        async let containers = try? client.containers()
        async let images = try? client.images()
        async let volumes = try? client.volumes()
        async let networks = try? client.networks()

        if let containers = await containers {
            catalog.replace(with: containers.map(Container.init))
        }
        if let images = await images { self.images = images }
        if let volumes = await volumes { self.volumes = volumes }
        if let networks = await networks { self.networks = networks }
        isLoaded = true
    }

    /// Feeds one event through the reducer and schedules whatever it couldn't answer alone.
    public func handle(_ event: DockerEvent) {
        schedule(catalog.apply(event))
    }

    private func schedule(_ effect: StoreEffect) {
        switch effect {
        case .none: return
        case let .reloadContainer(id): pendingContainers.insert(id)
        case .reloadContainers: pendingLists.insert(.containers)
        case .reloadImages: pendingLists.insert(.images)
        case .reloadVolumes: pendingLists.insert(.volumes)
        case .reloadNetworks: pendingLists.insert(.networks)
        }
        // A window already open will pick this up: rescheduling on every event would let a busy
        // stream postpone the flush forever.
        guard flush == nil else { return }
        flush = Task { [coalesceWindow] in
            try? await Task.sleep(for: coalesceWindow)
            await performPending()
        }
    }

    private func performPending() async {
        flush = nil
        let ids = pendingContainers
        let lists = pendingLists
        pendingContainers.removeAll()
        pendingLists.removeAll()

        // More than a couple of individual containers is cheaper as one list call.
        if ids.count > 3 || lists.contains(.containers) {
            if let containers = try? await client.containers() {
                catalog.replace(with: containers.map(Container.init))
            }
        } else {
            for id in ids { await refreshContainer(id) }
        }
        if lists.contains(.images), let images = try? await client.images() { self.images = images }
        if lists.contains(.volumes), let volumes = try? await client.volumes() { self.volumes = volumes }
        if lists.contains(.networks), let networks = try? await client.networks() { self.networks = networks }
    }

    /// Re-reads one container. A 404 means it vanished between the event and the fetch, which is
    /// normal for short-lived containers — the row is dropped rather than surfaced as an error.
    private func refreshContainer(_ id: String) async {
        do {
            let summaries = try await client.containers()
            if let match = summaries.first(where: { $0.id == id }) {
                catalog.upsert(Container(match))
            } else {
                catalog.remove(id: id)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Container actions

    public func start(_ container: Container) async { await act(container) { try await $0.start($1) } }
    public func stop(_ container: Container) async { await act(container) { try await $0.stop($1, timeout: 10) } }
    public func restart(_ container: Container) async { await act(container) { try await $0.restart($1) } }
    public func kill(_ container: Container) async { await act(container) { try await $0.kill($1) } }

    public func remove(_ container: Container) async {
        await act(container) { try await $0.remove($1, force: true) }
    }

    public func start(_ containers: [Container]) async { await forEach(containers, start) }
    public func stop(_ containers: [Container]) async { await forEach(containers, stop) }
    public func remove(_ containers: [Container]) async { await forEach(containers, remove) }

    /// A container's live detail, for the inspector.
    public func detail(_ id: String) async -> ContainerDetail? {
        try? await client.container(id)
    }

    // MARK: - Images, volumes, networks

    public func removeImage(_ image: ImageSummary) async {
        await run { try await self.client.removeImage(image.repoTags.first ?? image.id, force: true) }
        if let images = try? await client.images() { self.images = images }
    }

    public func pruneImages() async {
        await run { try await self.client.pruneImages() }
        if let images = try? await client.images() { self.images = images }
    }

    public func createVolume(name: String) async {
        await run { try await self.client.createVolume(name: name) }
    }

    public func removeVolume(_ volume: VolumeSummary) async {
        await run { try await self.client.removeVolume(volume.name, force: true) }
    }

    public func createNetwork(name: String, subnet: String?) async {
        await run { try await self.client.createNetwork(name: name, subnet: subnet) }
    }

    public func removeNetwork(_ network: NetworkSummary) async {
        await run { try await self.client.removeNetwork(network.id) }
    }

    /// Streams a pull, yielding the daemon's progress lines.
    public func pull(_ reference: String) -> AsyncThrowingStream<PullProgress, any Error> {
        client.pull(reference)
    }

    // MARK: - Plumbing

    private func act(_ container: Container,
                     _ body: @escaping (DockerClient, String) async throws -> Void) async {
        busy.insert(container.id)
        defer { busy.remove(container.id) }
        await run { try await body(self.client, container.id) }
    }

    private func forEach(_ containers: [Container], _ action: (Container) async -> Void) async {
        for container in containers { await action(container) }
    }

    /// Runs an action, surfacing failures instead of swallowing them. The resulting state change
    /// arrives on its own through the event feed — no optimistic patching, so what the user sees
    /// is always what the engine reports.
    private func run(_ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
