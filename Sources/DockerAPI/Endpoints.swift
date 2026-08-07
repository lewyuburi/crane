import Foundation
import NIOHTTP1

// MARK: - Containers

public extension DockerClient {
    /// `GET /containers/json`. `all` includes stopped containers, which is what the UI wants:
    /// hiding them would make a crashed service look deleted.
    func containers(all: Bool = true) async throws -> [ContainerSummary] {
        let data = try await data(.GET, "/containers/json", query: [.init(name: "all", value: all ? "1" : "0")])
        return try Self.decode([ContainerSummary].self, from: data)
    }

    func container(_ id: String) async throws -> ContainerDetail {
        try Self.decode(ContainerDetail.self, from: await data(.GET, "/containers/\(escape(id))/json"))
    }

    func start(_ id: String) async throws {
        try await lifecycle("start", id)
    }

    /// Stops a container, waiting up to `timeout` seconds before the daemon escalates to SIGKILL.
    func stop(_ id: String, timeout: Int? = nil) async throws {
        try await lifecycle("stop", id, query: timeout.map { [.init(name: "t", value: String($0))] } ?? [])
    }

    func restart(_ id: String) async throws {
        try await lifecycle("restart", id)
    }

    func kill(_ id: String, signal: String? = nil) async throws {
        try await lifecycle("kill", id, query: signal.map { [.init(name: "signal", value: $0)] } ?? [])
    }

    /// Removes a container. `force` kills it first; `volumes` also drops its anonymous volumes.
    func remove(_ id: String, force: Bool = false, volumes: Bool = false) async throws {
        _ = try await data(.DELETE, "/containers/\(escape(id))", query: [
            .init(name: "force", value: force ? "1" : "0"),
            .init(name: "v", value: volumes ? "1" : "0"),
        ])
    }

    /// A container's logs. With `follow` the stream stays open until the task is cancelled.
    ///
    /// - Parameter tty: pass the container's own TTY flag; it decides whether the daemon
    ///   multiplexes the streams or sends raw bytes.
    func logs(_ id: String, follow: Bool = true, tail: Int? = 500,
              tty: Bool = false) -> AsyncThrowingStream<LogChunk, any Error> {
        let query: [URLQueryItem] = [
            .init(name: "stdout", value: "1"),
            .init(name: "stderr", value: "1"),
            .init(name: "follow", value: follow ? "1" : "0"),
            .init(name: "tail", value: tail.map(String.init) ?? "all"),
        ]
        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = LogFrameDecoder(multiplexed: !tty)
                do {
                    for try await bytes in stream(.GET, "/containers/\(escape(id))/logs", query: query) {
                        for chunk in decoder.push(bytes) { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Live resource usage. One sample per second from the daemon; the caller turns pairs of
    /// samples into percentages.
    func stats(_ id: String) -> AsyncThrowingStream<StatsSample, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = LineSplitter()
                do {
                    for try await bytes in stream(.GET, "/containers/\(escape(id))/stats",
                                                  query: [.init(name: "stream", value: "1")]) {
                        for line in splitter.push(bytes) {
                            if let sample = try? JSONDecoder().decode(StatsSample.self, from: line) {
                                continuation.yield(sample)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One stats sample, for a row that isn't being watched continuously.
    func statsOnce(_ id: String) async throws -> StatsSample {
        let payload = try await data(.GET, "/containers/\(escape(id))/stats",
                                     query: [.init(name: "stream", value: "false")])
        return try Self.decode(StatsSample.self, from: payload)
    }

    /// Reads a path inside a container as a tar archive (`GET /containers/{id}/archive`).
    func archive(_ id: String, path: String) async throws -> Data {
        try await data(.GET, "/containers/\(escape(id))/archive",
                       query: [.init(name: "path", value: path)], limit: 512 << 20)
    }

    /// Writes a tar archive into a container's directory. This is `docker cp` into a container.
    func extractArchive(_ id: String, to path: String, tar: Data) async throws {
        _ = try await data(.PUT, "/containers/\(escape(id))/archive",
                           query: [.init(name: "path", value: path)], body: tar,
                           contentType: "application/x-tar")
    }

    func pruneContainers() async throws {
        _ = try await data(.POST, "/containers/prune")
    }

    private func lifecycle(_ action: String, _ id: String, query: [URLQueryItem] = []) async throws {
        _ = try await data(.POST, "/containers/\(escape(id))/\(action)", query: query)
    }
}

// MARK: - Images

public extension DockerClient {
    func images() async throws -> [ImageSummary] {
        try Self.decode([ImageSummary].self, from: await data(.GET, "/images/json"))
    }

    func removeImage(_ reference: String, force: Bool = false) async throws {
        _ = try await data(.DELETE, "/images/\(escape(reference))",
                           query: [.init(name: "force", value: force ? "1" : "0")])
    }

    func pruneImages() async throws {
        _ = try await data(.POST, "/images/prune")
    }

    /// Pulls an image, reporting the daemon's progress lines as they arrive.
    func pull(_ reference: String) -> AsyncThrowingStream<PullProgress, any Error> {
        let (name, tag) = Self.splitReference(reference)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = LineSplitter()
                do {
                    for try await bytes in stream(.POST, "/images/create", query: [
                        .init(name: "fromImage", value: name),
                        .init(name: "tag", value: tag),
                    ]) {
                        for line in splitter.push(bytes) {
                            guard let progress = try? JSONDecoder().decode(PullProgress.self, from: line) else { continue }
                            if let error = progress.error {
                                throw DockerError.api(status: 500, message: error)
                            }
                            continuation.yield(progress)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Splits `nginx:alpine` into name and tag, defaulting to `latest`. A digest reference keeps
    /// its `@sha256:…` in the name, where the daemon expects it.
    static func splitReference(_ reference: String) -> (name: String, tag: String) {
        guard !reference.contains("@") else { return (reference, "") }
        // Only a colon after the last slash is a tag; `registry:5000/app` is a port.
        guard let colon = reference.lastIndex(of: ":"),
              !reference[reference.index(after: colon)...].contains("/") else {
            return (reference, "latest")
        }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }
}

/// One line of `POST /images/create` progress.
public struct PullProgress: Sendable, Equatable, Decodable {
    public let status: String
    public let id: String?
    public let current: Int64?
    public let total: Int64?
    public let error: String?

    /// 0…1 for the layer this line is about, when the daemon reports byte counts.
    public var fraction: Double? {
        guard let current, let total, total > 0 else { return nil }
        return min(Double(current) / Double(total), 1)
    }

    private struct Detail: Decodable {
        let current: Int64?
        let total: Int64?
    }

    enum CodingKeys: String, CodingKey {
        case status, id, error, progressDetail
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        let detail = try c.decodeIfPresent(Detail.self, forKey: .progressDetail)
        current = detail?.current
        total = detail?.total
    }
}

// MARK: - Volumes and networks

public extension DockerClient {
    func volumes() async throws -> [VolumeSummary] {
        try Self.decode(VolumeList.self, from: await data(.GET, "/volumes")).volumes
    }

    func createVolume(name: String, labels: [String: String] = [:]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name, "Labels": labels])
        _ = try await data(.POST, "/volumes/create", body: body)
    }

    func removeVolume(_ name: String, force: Bool = false) async throws {
        _ = try await data(.DELETE, "/volumes/\(escape(name))",
                           query: [.init(name: "force", value: force ? "1" : "0")])
    }

    func pruneVolumes() async throws {
        _ = try await data(.POST, "/volumes/prune")
    }

    func networks() async throws -> [NetworkSummary] {
        try Self.decode([NetworkSummary].self, from: await data(.GET, "/networks"))
    }

    func createNetwork(name: String, subnet: String? = nil, internalOnly: Bool = false) async throws {
        var payload: [String: Any] = ["Name": name, "Internal": internalOnly]
        if let subnet {
            payload["IPAM"] = ["Config": [["Subnet": subnet]]]
        }
        _ = try await data(.POST, "/networks/create", body: try JSONSerialization.data(withJSONObject: payload))
    }

    func removeNetwork(_ id: String) async throws {
        _ = try await data(.DELETE, "/networks/\(escape(id))")
    }
}

// MARK: - Shared helpers

extension DockerClient {
    /// Percent-encodes a path segment. Container names are user input and can carry characters
    /// that would otherwise change the URL's shape.
    func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DockerError.decoding("\(T.self): \(error)")
        }
    }
}
