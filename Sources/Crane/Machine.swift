import Foundation

/// A `container machine` — a lightweight Linux VM you can shell into (the native
/// equivalent of OrbStack's Linux machines).
struct Machine: Identifiable, Hashable {
    let id: String
    var status: String
    var ipAddress: String?
    var cpus: Int
    var memoryBytes: Int64
    var diskSizeBytes: Int64
    var isDefault: Bool

    var isRunning: Bool { status.lowercased() == "running" }
    var statusValue: ContainerStatus { ContainerStatus(rawValue: status) }
}

enum MachineDecoding {
    static func decode(from data: Data) -> [Machine] {
        guard !data.isEmpty,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { obj in
            guard let id = obj["id"] as? String else { return nil }
            func int(_ key: String) -> Int64 { (obj[key] as? NSNumber)?.int64Value ?? 0 }
            return Machine(
                id: id,
                status: (obj["status"] as? String) ?? "unknown",
                ipAddress: obj["ipAddress"] as? String,
                cpus: (obj["cpus"] as? NSNumber)?.intValue ?? 0,
                memoryBytes: int("memory"),
                diskSizeBytes: int("diskSize"),
                isDefault: (obj["default"] as? Bool) ?? false
            )
        }
    }
}
