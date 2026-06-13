import Foundation

/// A `container volume`.
struct Volume: Identifiable, Hashable {
    let id: String
    var name: String
    var driver: String
    var format: String
    var sizeInBytes: Int64
    var source: String
}

/// A `container network`.
struct Network: Identifiable, Hashable {
    let id: String
    var name: String
    var mode: String
    var plugin: String
    var ipv4Subnet: String?
    var ipv4Gateway: String?
}

/// `container system df` — disk usage per resource type.
struct DiskUsage: Hashable {
    struct Entry: Hashable {
        let total: Int
        let active: Int
        let sizeInBytes: Int64
        let reclaimableInBytes: Int64
    }
    var images: Entry
    var containers: Entry
    var volumes: Entry
}

enum VolumeNetworkDecoding {
    private static func objects(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array
    }

    static func decodeVolumes(from data: Data) -> [Volume] {
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

    static func decodeNetworks(from data: Data) -> [Network] {
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

    static func decodeDiskUsage(from data: Data) -> DiskUsage? {
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
