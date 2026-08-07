import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix

/// Crane's connection to the Docker-compatible engine.
///
/// Everything the UI shows comes through here over a UNIX socket — no subprocesses. The client
/// is long-lived: one instance for the app's lifetime, so connections are pooled and a request
/// costs a round-trip rather than a `fork`/`exec`.
public final class DockerClient: Sendable {
    /// The Engine API version Crane targets. socktainer tracks v1.51.
    public static let apiVersion = "v1.51"

    public let socket: DockerSocket
    private let http: HTTPClient

    public init(socket: DockerSocket = .socktainer) {
        self.socket = socket
        var configuration = HTTPClient.Configuration()
        // A local socket either answers immediately or isn't there; a long connect timeout would
        // just make "engine not running" feel like a hang.
        configuration.timeout.connect = .seconds(2)
        configuration.timeout.read = nil          // streams (events, logs, stats) must not time out
        self.http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }

    /// Releases the connection pool. The app calls this on termination; tests call it per case.
    public func shutdown() async {
        try? await http.shutdown()
    }

    // MARK: - Endpoints

    /// `GET /_ping` — the cheapest liveness check. Returns false instead of throwing when the
    /// engine simply isn't up, because "is it running?" is a question, not an error.
    public func ping() async -> Bool {
        guard socket.exists else { return false }
        return (try? await data(.GET, "/_ping")) != nil
    }

    public func version() async throws -> DockerVersion {
        try Self.decode(DockerVersion.self, from: await data(.GET, "/version"))
    }

    public func info() async throws -> DockerInfo {
        try Self.decode(DockerInfo.self, from: await data(.GET, "/info"))
    }

    /// `GET /events` — the push feed that keeps Crane's state fresh.
    ///
    /// The stream ends when the task is cancelled or the engine goes away; reconnection is the
    /// caller's decision (the store retries with backoff, so a daemon restart heals itself).
    public func events(since: Date? = nil) -> AsyncThrowingStream<DockerEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var query: [URLQueryItem] = []
                    if let since {
                        query.append(URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970))))
                    }
                    var splitter = LineSplitter()
                    let decoder = JSONDecoder()
                    for try await chunk in stream(.GET, "/events", query: query) {
                        for line in splitter.push(chunk) {
                            // A malformed or unknown-shaped line must not kill the feed.
                            if let event = try? decoder.decode(DockerEvent.self, from: line) {
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transport

    /// Performs a request and returns its body, mapping failures onto `DockerError`.
    func data(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [],
              body: Data? = nil, limit: Int = 32 << 20,
              contentType: String = "application/json") async throws -> Data {
        var request = HTTPClientRequest(url: socket.url(Self.prefixed(path), query: query))
        request.method = method
        if let body {
            request.headers.add(name: "Content-Type", value: contentType)
            request.body = .bytes(ByteBuffer(data: body))
        }
        // Both the connect and the body read can fail with the same underlying cause: over
        // Network.framework the failure often only surfaces while reading, so mapping just the
        // `execute` call would leak a raw POSIX error to the UI.
        let payload: Data
        do {
            let response = try await http.execute(request, timeout: .seconds(30))
            let buffer = try await response.body.collect(upTo: limit)
            payload = Data(buffer.readableBytesView)
            guard (200..<300).contains(response.status.code) else {
                throw DockerError.from(status: response.status.code, body: payload)
            }
        } catch {
            throw Self.mapTransport(error, socket: socket)
        }
        return payload
    }

    /// Performs a request and yields body chunks as they arrive, for the streaming endpoints.
    func stream(_ method: HTTPMethod, _ path: String,
                query: [URLQueryItem] = []) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = HTTPClientRequest(url: socket.url(Self.prefixed(path), query: query))
                    request.method = method
                    let response = try await http.execute(request, deadline: .distantFuture)
                    guard (200..<300).contains(response.status.code) else {
                        let buffer = try await response.body.collect(upTo: 1 << 20)
                        throw DockerError.from(status: response.status.code,
                                               body: Data(buffer.readableBytesView))
                    }
                    for try await buffer in response.body {
                        continuation.yield(Data(buffer.readableBytesView))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransport(error, socket: socket))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    /// Prefixes an endpoint with the API version, unless it already carries it.
    ///
    /// The test for "already prefixed" has to be the full `/v1.51/`: matching a bare `/v` would
    /// quietly leave `/version` unversioned.
    static func prefixed(_ path: String) -> String {
        path.hasPrefix("/\(apiVersion)/") ? path : "/\(apiVersion)\(path)"
    }

    /// A connect-time failure means the engine isn't listening — the one case the diagnostics
    /// panel can actually fix, so it gets its own error rather than a raw POSIX code.
    ///
    /// On Apple platforms AsyncHTTPClient runs over Network.framework, so these arrive as
    /// `NWPOSIXError` (bridged into `NSPOSIXErrorDomain`) rather than as NIO errors — matching on
    /// NIO types alone would have let "No such file or directory" reach the user.
    static func mapTransport(_ error: any Error, socket: DockerSocket) -> any Error {
        if error is DockerError { return error }
        if let http = error as? HTTPClientError,
           http == .connectTimeout || http == .remoteConnectionClosed {
            return DockerError.notRunning(socket: socket.path)
        }
        if error is NIOConnectionError || error is ChannelError {
            return DockerError.notRunning(socket: socket.path)
        }
        if let network = error as? HTTPClient.NWPOSIXError,
           Self.connectionFailureCodes.contains(network.errorCode.rawValue) {
            return DockerError.notRunning(socket: socket.path)
        }
        let posix = error as NSError
        if posix.domain == NSPOSIXErrorDomain, Self.connectionFailureCodes.contains(Int32(posix.code)) {
            return DockerError.notRunning(socket: socket.path)
        }
        return error
    }

    /// Everything the OS reports when a socket is absent, stale, or refusing: no such file,
    /// not a socket, connection refused/reset, network down, broken pipe.
    private static let connectionFailureCodes: Set<Int32> = [
        ENOENT, ENOTSOCK, ECONNREFUSED, ECONNRESET, ECONNABORTED, ENETDOWN, EPIPE, ETIMEDOUT,
    ]
}
