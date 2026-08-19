import DockerAPI
import Foundation
import Observation

/// One stream that a `LogSession` tails. A stack view passes one source per service.
public struct LogSource: Sendable {
    public let containerID: String
    public let label: String
    public let tty: Bool

    public init(containerID: String, label: String = "", tty: Bool = false) {
        self.containerID = containerID
        self.label = label
        self.tty = tty
    }
}

/// A live tail of one or more containers' output.
///
/// The text itself never accumulates here: chunks are handed straight to whoever is drawing them
/// (an AppKit text view that trims its own backing store). Keeping megabytes of log in an
/// observable property would redraw the whole console on every line.
@MainActor
@Observable
public final class LogSession {
    public private(set) var isStreaming = false
    public var failure: String?

    private let client: DockerClient
    private let sources: [LogSource]
    /// `nonisolated(unsafe)` so `deinit` can cancel it: a `Task` handle is safe to cancel from
    /// any thread, and a session that outlives its view must not keep streaming.
    nonisolated(unsafe) private var task: Task<Void, Never>?
    private var sink: (@MainActor (String) -> Void)?

    public init(client: DockerClient, containerID: String, tty: Bool = false) {
        self.client = client
        self.sources = [LogSource(containerID: containerID, tty: tty)]
    }

    public init(client: DockerClient, sources: [LogSource]) {
        self.client = client
        self.sources = sources
    }

    /// Starts streaming, delivering chunks to `sink`. Re-calling replaces the sink and restarts.
    public func start(tail: Int = 1000, sink: @escaping @MainActor (String) -> Void) {
        stop()
        self.sink = sink
        isStreaming = true
        failure = nil
        let prefix = sources.count > 1
        task = Task { [client, sources] in
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            for try await chunk in client.logs(source.containerID, follow: true,
                                                               tail: tail, tty: source.tty) {
                                guard !Task.isCancelled else { break }
                                let text = prefix && !source.label.isEmpty
                                    ? "[\(source.label)] \(chunk.text)"
                                    : chunk.text
                                await sink(text)
                            }
                        } catch {
                            await MainActor.run { self.failure = error.localizedDescription }
                        }
                    }
                }
            }
            await MainActor.run { self.isStreaming = false }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    deinit {
        task?.cancel()
    }
}
