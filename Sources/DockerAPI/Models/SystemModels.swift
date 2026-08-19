import Foundation

/// `GET /version`. Only the fields Crane shows or gates on — the daemon sends more.
public struct DockerVersion: Sendable, Equatable, Decodable {
    public let version: String
    public let apiVersion: String
    public let os: String
    public let arch: String
    /// Named components the daemon is built from. socktainer reports itself and the Apple
    /// runtime here, which is exactly the pair Crane pins.
    public let components: [Component]

    public struct Component: Sendable, Equatable, Decodable {
        public let name: String
        public let version: String

        enum CodingKeys: String, CodingKey { case name = "Name", version = "Version" }
    }

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case os = "Os"
        case arch = "Arch"
        case components = "Components"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? ""
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        components = try c.decodeIfPresent([Component].self, forKey: .components) ?? []
    }

    public init(version: String, apiVersion: String, os: String = "", arch: String = "",
                components: [Component] = []) {
        self.version = version
        self.apiVersion = apiVersion
        self.os = os
        self.arch = arch
        self.components = components
    }

    /// The version reported for a component, matched case-insensitively by prefix
    /// (socktainer labels the runtime "Apple Container", say, not "container").
    public func component(_ name: String) -> String? {
        components.first { $0.name.lowercased().contains(name.lowercased()) }?.version
    }
}

/// `GET /info`, narrowed to what Crane actually reads from the daemon.
public struct DockerInfo: Sendable, Equatable, Decodable {
    public let containers: Int
    public let containersRunning: Int
    public let images: Int
    public let serverVersion: String
    public let operatingSystem: String
    public let architecture: String
    public let cpus: Int
    public let memoryBytes: Int64
    public let rootDirectory: String

    enum CodingKeys: String, CodingKey {
        case containers = "Containers"
        case containersRunning = "ContainersRunning"
        case images = "Images"
        case serverVersion = "ServerVersion"
        case operatingSystem = "OperatingSystem"
        case architecture = "Architecture"
        case cpus = "NCPU"
        case memoryBytes = "MemTotal"
        case rootDirectory = "DockerRootDir"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        containers = try c.decodeIfPresent(Int.self, forKey: .containers) ?? 0
        containersRunning = try c.decodeIfPresent(Int.self, forKey: .containersRunning) ?? 0
        images = try c.decodeIfPresent(Int.self, forKey: .images) ?? 0
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        operatingSystem = try c.decodeIfPresent(String.self, forKey: .operatingSystem) ?? ""
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? ""
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 0
        memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryBytes) ?? 0
        rootDirectory = try c.decodeIfPresent(String.self, forKey: .rootDirectory) ?? ""
    }
}
