import Foundation

/// One sample of a container's resource usage (`container stats --format json`).
public struct ContainerStats: Sendable {
    public let id: String
    public let cpuUsageUsec: Int64
    public let memoryUsageBytes: Int64
    public let memoryLimitBytes: Int64
    public let blockReadBytes: Int64
    public let blockWriteBytes: Int64
    public let networkRxBytes: Int64
    public let networkTxBytes: Int64
    public let numProcesses: Int

    public var memoryFraction: Double {
        memoryLimitBytes > 0 ? Double(memoryUsageBytes) / Double(memoryLimitBytes) : 0
    }
}

public enum StatsDecoding: Sendable {
    public static func decode(from data: Data) -> [ContainerStats] {
        guard !data.isEmpty,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { obj in
            guard let id = obj["id"] as? String else { return nil }
            func int(_ key: String) -> Int64 { (obj[key] as? NSNumber)?.int64Value ?? 0 }
            return ContainerStats(
                id: id,
                cpuUsageUsec: int("cpuUsageUsec"),
                memoryUsageBytes: int("memoryUsageBytes"),
                memoryLimitBytes: int("memoryLimitBytes"),
                blockReadBytes: int("blockReadBytes"),
                blockWriteBytes: int("blockWriteBytes"),
                networkRxBytes: int("networkRxBytes"),
                networkTxBytes: int("networkTxBytes"),
                numProcesses: (obj["numProcesses"] as? NSNumber)?.intValue ?? 0
            )
        }
    }
}

