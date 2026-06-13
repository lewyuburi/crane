import Foundation
import Observation

/// One sample of a container's resource usage (`container stats --format json`).
struct ContainerStats {
    let id: String
    let cpuUsageUsec: Int64
    let memoryUsageBytes: Int64
    let memoryLimitBytes: Int64
    let blockReadBytes: Int64
    let blockWriteBytes: Int64
    let networkRxBytes: Int64
    let networkTxBytes: Int64
    let numProcesses: Int

    var memoryFraction: Double {
        memoryLimitBytes > 0 ? Double(memoryUsageBytes) / Double(memoryLimitBytes) : 0
    }
}

enum StatsDecoding {
    static func decode(from data: Data) -> [ContainerStats] {
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

/// Polls `container stats` for one container and derives a live CPU percentage.
///
/// `cpuUsageUsec` is cumulative CPU time, so CPU% = Δusage / Δwallclock between two
/// samples. We poll rather than stream so each tick runs through ProcessRunner (off
/// the cooperative pool) and is trivially cancellable.
@MainActor
@Observable
final class StatsPoller {
    private(set) var latest: ContainerStats?
    private(set) var cpuPercent: Double = 0

    private let containerID: String
    private var task: Task<Void, Never>?
    private var lastUsageUsec: Int64?
    private let intervalSeconds: UInt64 = 2

    init(containerID: String) {
        self.containerID = containerID
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .seconds(self.intervalSeconds))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        guard let sample = await ContainerCLI.shared.stats(id: containerID) else { return }
        if let previous = lastUsageUsec {
            let deltaUsage = Double(sample.cpuUsageUsec - previous)
            let deltaWallUsec = Double(intervalSeconds) * 1_000_000
            cpuPercent = max(0, min(deltaUsage / deltaWallUsec * 100, 100 * 64))
        }
        lastUsageUsec = sample.cpuUsageUsec
        latest = sample
    }
}
