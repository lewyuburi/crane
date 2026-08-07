import DockerAPI
import Foundation
import Observation

/// A live tail of one container's output.
///
/// The text itself never accumulates here: chunks are handed straight to whoever is drawing them
/// (an AppKit text view that trims its own backing store). Keeping megabytes of log in an
/// observable property would redraw the whole console on every line.
@MainActor
@Observable
public final class LogSession {
    public private(set) var isStreaming = false
    public var failure: String?
    /// Set false to freeze the tail without dropping the connection.
    public var isFollowing = true

    private let client: DockerClient
    private let containerID: String
    private let tty: Bool
    /// `nonisolated(unsafe)` so `deinit` can cancel it: a `Task` handle is safe to cancel from
    /// any thread, and a session that outlives its view must not keep streaming.
    nonisolated(unsafe) private var task: Task<Void, Never>?
    private var sink: (@MainActor (String) -> Void)?

    public init(client: DockerClient, containerID: String, tty: Bool = false) {
        self.client = client
        self.containerID = containerID
        self.tty = tty
    }

    /// Starts streaming, delivering chunks to `sink`. Re-calling replaces the sink and restarts.
    public func start(tail: Int = 1000, sink: @escaping @MainActor (String) -> Void) {
        stop()
        self.sink = sink
        isStreaming = true
        failure = nil
        task = Task { [client, containerID, tty] in
            do {
                for try await chunk in client.logs(containerID, follow: true, tail: tail, tty: tty) {
                    guard !Task.isCancelled else { break }
                    if isFollowing { self.sink?(chunk.text) }
                }
            } catch {
                failure = error.localizedDescription
            }
            isStreaming = false
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
