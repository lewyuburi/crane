import DockerAPI
import Foundation

/// A container as Crane shows it.
///
/// Deliberately narrower than the API's summary: this is what the list and detail views read,
/// and keeping it a value type is what lets the reducer be pure.
public struct Container: Identifiable, Sendable, Equatable {
    public enum RunState: String, Sendable, Equatable {
        case created, running, paused, restarting, exited, dead, unknown

        public var isRunning: Bool { self == .running || self == .restarting }

        init(_ raw: String) {
            self = RunState(rawValue: raw.lowercased()) ?? .unknown
        }
    }

    /// Only set when the image or Compose file defines a healthcheck.
    public enum Health: String, Sendable, Equatable {
        case starting, healthy, unhealthy

        init?(_ raw: String?) {
            guard let raw, let value = Health(rawValue: raw.lowercased()) else { return nil }
            self = value
        }
    }

    public let id: String
    public var name: String
    public var image: String
    public var state: RunState
    /// The daemon's own phrasing, e.g. "Up 3 seconds".
    public var statusText: String
    public var health: Health?
    public var exitCode: Int?
    public var ports: [PortBinding]
    public var created: Date
    /// Network name → address.
    public var addresses: [String: String]
    public var labels: [String: String]

    public var project: String? { labels["com.docker.compose.project"] }
    public var service: String? { labels["com.docker.compose.service"] }
    public var isRunning: Bool { state.isRunning }

    /// Ports published to the host, lowest first — the ones worth offering as links.
    public var publishedPorts: [PortBinding] {
        ports.filter { $0.hostPort != nil }.sorted { ($0.hostPort ?? 0) < ($1.hostPort ?? 0) }
    }

    public init(_ summary: ContainerSummary) {
        id = summary.id
        name = summary.name
        image = summary.image
        state = RunState(summary.state)
        statusText = summary.status
        health = nil
        exitCode = nil
        ports = summary.ports
        created = summary.created
        addresses = summary.addresses
        labels = summary.labels
    }

    public init(id: String, name: String, image: String = "", state: RunState = .running,
                statusText: String = "", health: Health? = nil, exitCode: Int? = nil,
                ports: [PortBinding] = [], created: Date = .distantPast,
                addresses: [String: String] = [:], labels: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.statusText = statusText
        self.health = health
        self.exitCode = exitCode
        self.ports = ports
        self.created = created
        self.addresses = addresses
        self.labels = labels
    }
}

/// A Compose project: the containers that share a `com.docker.compose.project` label.
public struct Project: Identifiable, Sendable, Equatable {
    public let name: String
    public var containers: [Container]

    public var id: String { name }
    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var isFullyUp: Bool { !containers.isEmpty && runningCount == containers.count }

    public init(name: String, containers: [Container]) {
        self.name = name
        self.containers = containers
    }
}

/// How the sidebar and list group what's running: projects first, then loose containers.
public struct ContainerGrouping: Sendable, Equatable {
    public let projects: [Project]
    public let standalone: [Container]

    /// Groups by Compose project, ordering projects and containers by name so the list never
    /// jumps around when an event arrives.
    public init(_ containers: [Container]) {
        let byProject = Dictionary(grouping: containers.filter { $0.project != nil }) { $0.project! }
        projects = byProject
            .map { Project(name: $0.key, containers: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
        standalone = containers.filter { $0.project == nil }.sorted { $0.name < $1.name }
    }
}
