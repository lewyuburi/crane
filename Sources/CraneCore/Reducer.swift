import DockerAPI
import Foundation

/// What the store must do after an event, beyond the state change the reducer already made.
///
/// Events say *what happened*, not *what the row looks like now*: a `start` brings published
/// ports into existence, a `create` has no row yet at all. Naming those follow-ups as data keeps
/// the reducer pure — the store decides when to spend a round-trip.
public enum StoreEffect: Sendable, Equatable {
    case none
    /// Re-fetch one container; its shape may have changed.
    case reloadContainer(id: String)
    case reloadContainers
    case reloadImages
    case reloadVolumes
    case reloadNetworks
}

/// The container list, and the rules for how a Docker event changes it.
///
/// This is the heart of the "no polling" claim: every visible state change flows through here,
/// which is why it is a plain value type with no networking in sight.
public struct ContainerCatalog: Sendable, Equatable {
    /// Sorted by name so the UI has a stable order regardless of event arrival order.
    public private(set) var containers: [Container] = []

    public init(_ containers: [Container] = []) {
        self.containers = containers.sorted { $0.name < $1.name }
    }

    public var grouping: ContainerGrouping { ContainerGrouping(containers) }

    public subscript(id: String) -> Container? {
        containers.first { $0.id == id }
    }

    /// Replaces everything — the snapshot path, used at launch and after a reconnect.
    public mutating func replace(with containers: [Container]) {
        self.containers = containers.sorted { $0.name < $1.name }
    }

    /// Inserts or updates one container, keeping the sort stable.
    public mutating func upsert(_ container: Container) {
        if let index = containers.firstIndex(where: { $0.id == container.id }) {
            containers[index] = container
        } else {
            containers.append(container)
        }
        containers.sort { $0.name < $1.name }
    }

    public mutating func remove(id: String) {
        containers.removeAll { $0.id == id }
    }

    /// Applies an event and says what still needs fetching.
    @discardableResult
    public mutating func apply(_ event: DockerEvent) -> StoreEffect {
        switch event.subject {
        case .container: return applyContainerEvent(event)
        case .image: return .reloadImages
        case .volume: return .reloadVolumes
        case .network: return .reloadNetworks
        case .daemon, .plugin, .builder, .unknown: return .none
        }
    }

    private mutating func applyContainerEvent(_ event: DockerEvent) -> StoreEffect {
        let action = event.action
        guard let index = containers.firstIndex(where: { $0.id == event.id }) else {
            // Unknown container: anything but its removal means we're missing a row.
            return action == "destroy" || action == "remove" ? .none : .reloadContainer(id: event.id)
        }

        if let health = Container.Health(event.healthStatus) {
            containers[index].health = health
            return .none
        }

        switch action {
        case "destroy", "remove":
            containers.remove(at: index)
            return .none

        case "die", "stop", "kill", "oom":
            containers[index].state = .exited
            containers[index].health = nil          // a stopped container has no health
            containers[index].exitCode = event.attributes["exitCode"].flatMap(Int.init)
            containers[index].statusText = Self.exitedStatus(code: containers[index].exitCode)
            return .none

        case "pause":
            containers[index].state = .paused
            return .none

        case "start", "unpause", "restart":
            // Ports and addresses only exist once it's up, and the event doesn't carry them.
            containers[index].state = .running
            containers[index].statusText = "Starting…"
            return .reloadContainer(id: event.id)

        case "rename":
            if let name = event.attributes["name"] ?? event.name {
                containers[index].name = name
                containers.sort { $0.name < $1.name }
            }
            return .none

        case "update":
            return .reloadContainer(id: event.id)

        default:
            // exec_*, attach, resize, top… nothing visible changed.
            return event.affectsContainerList ? .reloadContainer(id: event.id) : .none
        }
    }

    private static func exitedStatus(code: Int?) -> String {
        guard let code else { return "Exited" }
        return "Exited (\(code))"
    }
}
