import Foundation
import Observation
import CraneKit

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
