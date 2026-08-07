import DockerAPI
import Foundation

/// What the store hears from the engine.
public enum FeedSignal: Sendable, Equatable {
    /// The feed is live. Always preceded by `resync`, never the other way round.
    case connected
    /// The connection dropped; the feed is retrying on its own.
    case disconnected(String?)
    /// Reload snapshots: either this is the first connection, or events were missed while down.
    case resync
    case event(DockerEvent)
}

/// Keeps a live `/events` subscription and turns its lifecycle into signals.
///
/// This is what lets Crane never poll. The reconnection policy lives here rather than in the
/// store, so the store only ever handles two cases: "here is an event" and "your snapshot is
/// stale, reload it".
public actor EventFeed {
    private let client: DockerClient
    private var task: Task<Void, Never>?

    public init(client: DockerClient) {
        self.client = client
    }

    /// Starts the feed and returns its signals. Cancelling the consuming task stops the feed.
    public func signals() -> AsyncStream<FeedSignal> {
        AsyncStream<FeedSignal> { continuation in
            let task = Task { await run { continuation.yield($0) } }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func run(yield: @Sendable @escaping (FeedSignal) -> Void) async {
        var backoff = Backoff()
        while !Task.isCancelled {
            // Confirm the daemon answers before claiming to be connected: the events request
            // itself only fails once the first chunk is read, which would make a dead socket
            // look live for as long as nothing happens.
            guard await client.ping() else {
                yield(.disconnected(nil))
                try? await Task.sleep(for: backoff.next())
                continue
            }
            // A reconnect means we may have missed events; the snapshot has to be reloaded
            // before the first new event is applied, or the store would drift.
            yield(.resync)
            yield(.connected)
            backoff.reset()
            var failure: String?
            do {
                for try await event in client.events() {
                    if Task.isCancelled { return }
                    yield(.event(event))
                }
            } catch {
                failure = error.localizedDescription
            }
            if Task.isCancelled { return }
            yield(.disconnected(failure))
            try? await Task.sleep(for: backoff.next())
        }
    }
}
