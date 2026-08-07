import DockerAPI
import Foundation
import Observation

/// Live resource usage for one container, with enough history to draw a line.
///
/// The daemon sends cumulative counters once a second; percentages only exist between two
/// samples, so the arithmetic lives here rather than in the view.
@MainActor
@Observable
public final class StatsSession {
    /// One second per sample, so this is the last two minutes.
    public static let historyLength = 120

    public private(set) var latest: StatsSample?
    public private(set) var cpuPercent: Double = 0
    /// Recent CPU percentages, oldest first.
    public private(set) var cpuHistory: [Double] = []
    /// Recent memory fractions (0…1), oldest first.
    public private(set) var memoryHistory: [Double] = []
    public var failure: String?

    private let client: DockerClient
    private let containerID: String
    private var previous: StatsSample?
    /// `nonisolated(unsafe)` so `deinit` can cancel it: a `Task` handle is safe to cancel from
    /// any thread, and a session that outlives its view must not keep streaming.
    nonisolated(unsafe) private var task: Task<Void, Never>?

    public init(client: DockerClient, containerID: String) {
        self.client = client
        self.containerID = containerID
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [client, containerID] in
            do {
                for try await sample in client.stats(containerID) {
                    guard !Task.isCancelled else { break }
                    ingest(sample)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func ingest(_ sample: StatsSample) {
        cpuPercent = sample.cpuPercent(previous: previous)
        previous = sample
        latest = sample
        cpuHistory.append(cpuPercent)
        memoryHistory.append(sample.memoryFraction)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst() }
        if memoryHistory.count > Self.historyLength { memoryHistory.removeFirst() }
    }

    deinit {
        task?.cancel()
    }
}
