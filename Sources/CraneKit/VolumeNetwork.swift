import Foundation

/// A `container volume`.
public struct Volume: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var driver: String
    public var format: String
    public var sizeInBytes: Int64
    public var source: String
}

/// A `container network`.
public struct Network: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var mode: String
    public var plugin: String
    public var ipv4Subnet: String?
    public var ipv4Gateway: String?
}

/// `container system df` — disk usage per resource type.
public struct DiskUsage: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let total: Int
        public let active: Int
        public let sizeInBytes: Int64
        public let reclaimableInBytes: Int64
    }
    public var images: Entry
    public var containers: Entry
    public var volumes: Entry
}

public enum VolumeNetworkDecoding: Sendable {
    private static func objects(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array
    }

    public static func decodeVolumes(from data: Data) -> [Volume] {
        objects(data).compactMap { obj in
            let config = obj["configuration"] as? [String: Any] ?? obj
            guard let name = (config["name"] as? String) ?? (obj["id"] as? String) else { return nil }
            return Volume(
                id: (obj["id"] as? String) ?? name,
                name: name,
                driver: (config["driver"] as? String) ?? "local",
                format: (config["format"] as? String) ?? "",
                sizeInBytes: (config["sizeInBytes"] as? NSNumber)?.int64Value ?? 0,
                source: (config["source"] as? String) ?? ""
            )
        }
    }

    public static func decodeNetworks(from data: Data) -> [Network] {
        objects(data).compactMap { obj in
            let config = obj["configuration"] as? [String: Any] ?? obj
            let status = obj["status"] as? [String: Any]
            guard let name = (config["name"] as? String) ?? (obj["id"] as? String) else { return nil }
            return Network(
                id: (obj["id"] as? String) ?? name,
                name: name,
                mode: (config["mode"] as? String) ?? "",
                plugin: (config["plugin"] as? String) ?? "",
                ipv4Subnet: status?["ipv4Subnet"] as? String,
                ipv4Gateway: status?["ipv4Gateway"] as? String
            )
        }
    }

    public static func decodeDiskUsage(from data: Data) -> DiskUsage? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func entry(_ key: String) -> DiskUsage.Entry {
            let e = obj[key] as? [String: Any] ?? [:]
            return DiskUsage.Entry(
                total: (e["total"] as? NSNumber)?.intValue ?? 0,
                active: (e["active"] as? NSNumber)?.intValue ?? 0,
                sizeInBytes: (e["sizeInBytes"] as? NSNumber)?.int64Value ?? 0,
                reclaimableInBytes: (e["reclaimable"] as? NSNumber)?.int64Value ?? 0
            )
        }
        return DiskUsage(images: entry("images"), containers: entry("containers"), volumes: entry("volumes"))
    }
}
