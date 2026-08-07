import Foundation

/// A published port, as `GET /containers/json` reports it.
public struct PortBinding: Sendable, Equatable, Decodable {
    public let ip: String?
    public let containerPort: Int
    public let hostPort: Int?
    public let proto: String

    enum CodingKeys: String, CodingKey {
        case ip = "IP", containerPort = "PrivatePort", hostPort = "PublicPort", proto = "Type"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = try c.decodeIfPresent(String.self, forKey: .ip)
        containerPort = try c.decodeIfPresent(Int.self, forKey: .containerPort) ?? 0
        hostPort = try c.decodeIfPresent(Int.self, forKey: .hostPort)
        proto = try c.decodeIfPresent(String.self, forKey: .proto) ?? "tcp"
    }

    public init(ip: String? = nil, containerPort: Int, hostPort: Int? = nil, proto: String = "tcp") {
        self.ip = ip
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.proto = proto
    }
}

/// A bind mount or volume attached to a container.
public struct MountPoint: Sendable, Equatable, Decodable {
    public let source: String
    public let destination: String
    public let name: String?
    public let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case source = "Source", destination = "Destination", name = "Name", rw = "RW"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        readOnly = !(try c.decodeIfPresent(Bool.self, forKey: .rw) ?? true)
    }
}

/// One entry from `GET /containers/json`.
///
/// This is the shape the list view is built from, so it decodes defensively: a container with an
/// odd field still shows up, because a missing row is worse than a missing detail.
public struct ContainerSummary: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    /// Docker sends names with a leading slash; they're stripped here.
    public let names: [String]
    public let image: String
    public let imageID: String
    public let command: String
    public let created: Date
    /// `running`, `exited`, `created`, …
    public let state: String
    /// Human text like "Up 3 seconds".
    public let status: String
    public let ports: [PortBinding]
    public let labels: [String: String]
    public let mounts: [MountPoint]
    /// Network name → IPv4 address.
    public let addresses: [String: String]

    public var name: String { names.first ?? id }

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", imageID = "ImageID", command = "Command"
        case created = "Created", state = "State", status = "Status", ports = "Ports"
        case labels = "Labels", mounts = "Mounts", networkSettings = "NetworkSettings"
    }

    private struct NetworkSettings: Decodable {
        struct Endpoint: Decodable {
            let address: String?
            enum CodingKeys: String, CodingKey { case address = "IPAddress" }
        }
        let networks: [String: Endpoint]?
        enum CodingKeys: String, CodingKey { case networks = "Networks" }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        names = (try c.decodeIfPresent([String].self, forKey: .names) ?? [])
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        created = Date(timeIntervalSince1970: try c.decodeIfPresent(Double.self, forKey: .created) ?? 0)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        ports = try c.decodeIfPresent([PortBinding].self, forKey: .ports) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        mounts = try c.decodeIfPresent([MountPoint].self, forKey: .mounts) ?? []
        let settings = try c.decodeIfPresent(NetworkSettings.self, forKey: .networkSettings)
        addresses = (settings?.networks ?? [:]).compactMapValues(\.address)
    }
}

/// `GET /containers/{id}/json`, narrowed to what the detail pane shows.
public struct ContainerDetail: Sendable, Equatable, Decodable {
    public struct State: Sendable, Equatable, Decodable {
        public let status: String
        public let running: Bool
        public let exitCode: Int
        public let startedAt: String
        public let finishedAt: String
        public let error: String
        /// `healthy` / `unhealthy` / `starting`, when the image or Compose defines a healthcheck.
        public let health: String?

        private struct Health: Decodable {
            let status: String?
            enum CodingKeys: String, CodingKey { case status = "Status" }
        }

        enum CodingKeys: String, CodingKey {
            case status = "Status", running = "Running", exitCode = "ExitCode"
            case startedAt = "StartedAt", finishedAt = "FinishedAt", error = "Error", health = "Health"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
            exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
            startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
            finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt) ?? ""
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            health = try c.decodeIfPresent(Health.self, forKey: .health)?.status
        }

        /// All-defaults state, used when the daemon omits the object entirely.
        public init(status: String = "", running: Bool = false, exitCode: Int = 0,
                    startedAt: String = "", finishedAt: String = "", error: String = "",
                    health: String? = nil) {
            self.status = status
            self.running = running
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.error = error
            self.health = health
        }
    }

    public struct Config: Sendable, Equatable, Decodable {
        public let environment: [String]
        public let command: [String]
        public let entrypoint: [String]
        public let workingDirectory: String
        public let user: String
        public let hostname: String
        public let tty: Bool

        enum CodingKeys: String, CodingKey {
            case environment = "Env", command = "Cmd", entrypoint = "Entrypoint"
            case workingDirectory = "WorkingDir", user = "User", hostname = "Hostname", tty = "Tty"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            environment = try c.decodeIfPresent([String].self, forKey: .environment) ?? []
            command = try c.decodeIfPresent([String].self, forKey: .command) ?? []
            entrypoint = try c.decodeIfPresent([String].self, forKey: .entrypoint) ?? []
            workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
            user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
            hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
            tty = try c.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        }

        public init(environment: [String] = [], command: [String] = [], entrypoint: [String] = [],
                    workingDirectory: String = "", user: String = "", hostname: String = "",
                    tty: Bool = false) {
            self.environment = environment
            self.command = command
            self.entrypoint = entrypoint
            self.workingDirectory = workingDirectory
            self.user = user
            self.hostname = hostname
            self.tty = tty
        }
    }

    public let id: String
    public let name: String
    public let image: String
    public let platform: String
    public let restartCount: Int
    public let restartPolicy: String?
    public let state: State
    public let config: Config
    public let mounts: [MountPoint]

    private struct HostConfig: Decodable {
        struct Policy: Decodable {
            let name: String?
            enum CodingKeys: String, CodingKey { case name = "Name" }
        }
        let restartPolicy: Policy?
        enum CodingKeys: String, CodingKey { case restartPolicy = "RestartPolicy" }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", image = "Image", platform = "Platform"
        case restartCount = "RestartCount", state = "State", config = "Config"
        case mounts = "Mounts", hostConfig = "HostConfig"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let rawName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        restartCount = try c.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? State()
        config = try c.decodeIfPresent(Config.self, forKey: .config) ?? Config()
        mounts = try c.decodeIfPresent([MountPoint].self, forKey: .mounts) ?? []
        let policy = try c.decodeIfPresent(HostConfig.self, forKey: .hostConfig)?.restartPolicy?.name
        restartPolicy = (policy?.isEmpty ?? true) ? nil : policy
    }
}
