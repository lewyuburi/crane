import DockerAPI
import Foundation

/// A container as Crane shows it.
///
/// Deliberately narrower than the API's summary: this is what the list and detail views read,
/// and keeping it a value type is what lets the reducer be pure.
public struct Container: Identifiable, Sendable, Equatable, Hashable {
    public enum RunState: String, Sendable, Equatable, Hashable {
        case created, running, paused, restarting, exited, dead, unknown

        public var isRunning: Bool { self == .running || self == .restarting }

        init(_ raw: String) {
            self = RunState(rawValue: raw.lowercased()) ?? .unknown
        }
    }

    /// Only set when the image or Compose file defines a healthcheck.
    public enum Health: String, Sendable, Equatable, Hashable {
        case starting, healthy, unhealthy

        init?(_ raw: String?) {
            guard let raw, let value = Health(rawValue: raw.lowercased()) else { return nil }
            self = value
        }
    }

    public let id: String
    public var name: String
    public var image: String
    public var imageID: String
    public var state: RunState
    /// The daemon's own phrasing, e.g. "Up 3 seconds".
    public var statusText: String
    public var health: Health?
    public var exitCode: Int?
    public var ports: [PortBinding]
    public var mounts: [MountPoint]
    public var created: Date
    /// Network name → address.
    public var addresses: [String: String]
    public var labels: [String: String]

    public var project: String? { labels["com.docker.compose.project"] }
    public var service: String? { labels["com.docker.compose.service"] }
    public var isRunning: Bool { state.isRunning }

    /// Identifier Apple's runtime understands: the container name. Socktainer's list/inspect
    /// SHA in `id` is not a valid Apple ID — `container exec` and `GET /containers/{id}/stats`
    /// both look the name up with Apple's client and 404 on the SHA.
    public var runtimeID: String { name }

    /// Ports published to the host, lowest first — the ones worth offering as links.
    public var publishedPorts: [PortBinding] {
        ports.filter { $0.hostPort != nil }.sorted { ($0.hostPort ?? 0) < ($1.hostPort ?? 0) }
    }

    /// True when this row was created from `image` — tag match or image ID prefix.
    public func uses(_ image: ImageSummary) -> Bool {
        if !imageID.isEmpty {
            let have = imageID.replacingOccurrences(of: "sha256:", with: "")
            let want = image.id.replacingOccurrences(of: "sha256:", with: "")
            if !want.isEmpty, have.hasPrefix(want) || want.hasPrefix(have.prefix(12)) { return true }
        }
        let tags = image.repoTags.filter { $0 != "<none>:<none>" }
        if tags.contains(self.image) || image.displayName == self.image { return true }
        return tags.contains { tag in
            tag.hasSuffix("/\(self.image)") || self.image.hasSuffix("/\(tag)") || self.image.hasSuffix(":\(tag)")
        }
    }

    public func uses(_ volume: VolumeSummary) -> Bool {
        mounts.contains { $0.name == volume.name || $0.source == volume.mountpoint }
    }

    public init(_ summary: ContainerSummary) {
        id = summary.id
        name = summary.name
        image = summary.image
        imageID = summary.imageID
        state = RunState(summary.state)
        statusText = summary.status
        health = nil
        exitCode = nil
        ports = summary.ports
        mounts = summary.mounts
        created = summary.created
        addresses = summary.addresses
        labels = summary.labels
    }

    public init(id: String, name: String, image: String = "", imageID: String = "",
                state: RunState = .running,
                statusText: String = "", health: Health? = nil, exitCode: Int? = nil,
                ports: [PortBinding] = [], mounts: [MountPoint] = [],
                created: Date = .distantPast,
                addresses: [String: String] = [:], labels: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.image = image
        self.imageID = imageID
        self.state = state
        self.statusText = statusText
        self.health = health
        self.exitCode = exitCode
        self.ports = ports
        self.mounts = mounts
        self.created = created
        self.addresses = addresses
        self.labels = labels
    }
}

/// A Compose project: the containers that share a `com.docker.compose.project` label.
public struct Project: Identifiable, Sendable, Equatable, Hashable {
    public let name: String
    public var containers: [Container]

    public var id: String { name }
    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var isFullyUp: Bool { !containers.isEmpty && runningCount == containers.count }
    public var isFullyStopped: Bool { runningCount == 0 }

    public var statusLabel: String {
        if isFullyUp { return "Running" }
        if isFullyStopped { return "Stopped" }
        return "Partial"
    }

    public var publishedPorts: [PortBinding] {
        containers.flatMap(\.publishedPorts).sorted { ($0.hostPort ?? 0) < ($1.hostPort ?? 0) }
    }

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
