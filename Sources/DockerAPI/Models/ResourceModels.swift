import Foundation

/// One entry from `GET /images/json`.
public struct ImageSummary: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let repoTags: [String]
    public let repoDigests: [String]
    public let size: Int64
    public let created: Date
    /// How many containers use it. `-1` when the daemon doesn't count.
    public let containers: Int
    public let labels: [String: String]

    /// `nginx:alpine` when tagged, else a short digest — never the empty string.
    public var displayName: String {
        repoTags.first { $0 != "<none>:<none>" }
            ?? "<untagged> \(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))"
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests", size = "Size"
        case created = "Created", containers = "Containers", labels = "Labels"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        repoDigests = try c.decodeIfPresent([String].self, forKey: .repoDigests) ?? []
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        created = Date(timeIntervalSince1970: try c.decodeIfPresent(Double.self, forKey: .created) ?? 0)
        containers = try c.decodeIfPresent(Int.self, forKey: .containers) ?? -1
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

/// One entry from `GET /volumes`.
public struct VolumeSummary: Sendable, Equatable, Decodable, Identifiable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    public let createdAt: String
    public let labels: [String: String]

    public var id: String { name }
    public var composeProject: String? { labels["com.docker.compose.project"] }

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint"
        case createdAt = "CreatedAt", labels = "Labels"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        mountpoint = try c.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

/// The envelope `GET /volumes` wraps its list in.
struct VolumeList: Decodable {
    let volumes: [VolumeSummary]
    enum CodingKeys: String, CodingKey { case volumes = "Volumes" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try c.decodeIfPresent([VolumeSummary].self, forKey: .volumes) ?? []
    }
}

/// One entry from `GET /networks`.
public struct NetworkSummary: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let subnet: String?
    public let gateway: String?
    public let internalOnly: Bool
    public let labels: [String: String]
    /// Container name → address on this network.
    public let attached: [String: String]

    /// Apple's runtime ships a `default` network Crane shouldn't offer to delete.
    public var isBuiltIn: Bool { labels["com.apple.container.resource.role"] == "builtin" }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", scope = "Scope", subnet = "Subnet"
        case gateway = "Gateway", internalOnly = "Internal", labels = "Labels", containers = "Containers"
    }

    private struct Attachment: Decodable {
        let address: String?
        enum CodingKeys: String, CodingKey { case address = "IPv4Address" }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        subnet = try c.decodeIfPresent(String.self, forKey: .subnet)
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway)
        internalOnly = try c.decodeIfPresent(Bool.self, forKey: .internalOnly) ?? false
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        attached = (try c.decodeIfPresent([String: Attachment].self, forKey: .containers) ?? [:])
            .compactMapValues(\.address)
    }
}

/// One `GET /containers/{id}/stats` sample.
///
/// The numbers are cumulative counters; turning them into a CPU percentage needs two samples,
/// which is what `StatsSample.cpuPercent(previous:)` does.
public struct StatsSample: Sendable, Equatable, Decodable {
    public let cpuTotal: UInt64
    public let systemCPU: UInt64
    public let onlineCPUs: Int
    public let memoryUsage: Int64
    public let memoryLimit: Int64
    public let processes: Int
    public let networkRx: Int64
    public let networkTx: Int64
    public let blockRead: Int64
    public let blockWrite: Int64

    public var memoryFraction: Double {
        memoryLimit > 0 ? min(Double(memoryUsage) / Double(memoryLimit), 1) : 0
    }

    /// CPU use since `previous`, as a percentage of one core times the online CPU count —
    /// the same definition `docker stats` prints.
    public func cpuPercent(previous: StatsSample?) -> Double {
        guard let previous else { return 0 }
        let cpuDelta = Double(cpuTotal &- previous.cpuTotal)
        let systemDelta = Double(systemCPU &- previous.systemCPU)
        guard cpuDelta > 0, systemDelta > 0 else { return 0 }
        return (cpuDelta / systemDelta) * Double(max(onlineCPUs, 1)) * 100
    }

    private struct CPUStats: Decodable {
        struct Usage: Decodable {
            let total: UInt64?
            enum CodingKeys: String, CodingKey { case total = "total_usage" }
        }
        let usage: Usage?
        let system: UInt64?
        let onlineCPUs: Int?
        enum CodingKeys: String, CodingKey {
            case usage = "cpu_usage", system = "system_cpu_usage", onlineCPUs = "online_cpus"
        }
    }

    private struct MemoryStats: Decodable {
        let usage: Int64?
        let limit: Int64?
    }

    private struct PidsStats: Decodable {
        let current: Int?
    }

    private struct NetworkStats: Decodable {
        let rx: Int64?
        let tx: Int64?
        enum CodingKeys: String, CodingKey { case rx = "rx_bytes", tx = "tx_bytes" }
    }

    private struct BlockStats: Decodable {
        struct Entry: Decodable {
            let op: String?
            let value: Int64?
        }
        let entries: [Entry]?
        enum CodingKeys: String, CodingKey { case entries = "io_service_bytes_recursive" }
    }

    enum CodingKeys: String, CodingKey {
        case cpu = "cpu_stats", memory = "memory_stats", pids = "pids_stats"
        case networks, blkio = "blkio_stats"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cpu = try c.decodeIfPresent(CPUStats.self, forKey: .cpu)
        cpuTotal = cpu?.usage?.total ?? 0
        systemCPU = cpu?.system ?? 0
        onlineCPUs = cpu?.onlineCPUs ?? 1
        let memory = try c.decodeIfPresent(MemoryStats.self, forKey: .memory)
        memoryUsage = memory?.usage ?? 0
        memoryLimit = memory?.limit ?? 0
        processes = try c.decodeIfPresent(PidsStats.self, forKey: .pids)?.current ?? 0
        // Interfaces are summed: a container with two NICs should read as one machine.
        let interfaces = try c.decodeIfPresent([String: NetworkStats].self, forKey: .networks) ?? [:]
        networkRx = interfaces.values.reduce(0) { $0 + ($1.rx ?? 0) }
        networkTx = interfaces.values.reduce(0) { $0 + ($1.tx ?? 0) }
        let blocks = try c.decodeIfPresent(BlockStats.self, forKey: .blkio)?.entries ?? []
        blockRead = blocks.filter { $0.op?.lowercased() == "read" }.reduce(0) { $0 + ($1.value ?? 0) }
        blockWrite = blocks.filter { $0.op?.lowercased() == "write" }.reduce(0) { $0 + ($1.value ?? 0) }
    }

    public init(cpuTotal: UInt64 = 0, systemCPU: UInt64 = 0, onlineCPUs: Int = 1,
                memoryUsage: Int64 = 0, memoryLimit: Int64 = 0, processes: Int = 0,
                networkRx: Int64 = 0, networkTx: Int64 = 0, blockRead: Int64 = 0, blockWrite: Int64 = 0) {
        self.cpuTotal = cpuTotal
        self.systemCPU = systemCPU
        self.onlineCPUs = onlineCPUs
        self.memoryUsage = memoryUsage
        self.memoryLimit = memoryLimit
        self.processes = processes
        self.networkRx = networkRx
        self.networkTx = networkTx
        self.blockRead = blockRead
        self.blockWrite = blockWrite
    }
}
