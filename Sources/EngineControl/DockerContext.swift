import CryptoKit
import Foundation

/// Registers Crane's endpoint as a Docker context, so `docker …` just works without anyone
/// exporting `DOCKER_HOST`.
///
/// The Docker CLI reads contexts from `~/.docker/contexts/meta/<sha256(name)>/meta.json` and the
/// selected one from `currentContext` in `~/.docker/config.json`. Crane writes both files itself
/// instead of shelling out to `docker context create`, so the context exists before the CLI is
/// even installed — and so socktainer is launched with `--no-docker-context`, leaving exactly one
/// context for this stack rather than two pointing at the same socket.
public struct DockerContext: Sendable {
    public static let name = "crane"
    public static let description = "Crane — Apple container via socktainer"

    public let socketPath: String
    public let dockerHome: URL

    public init(socketPath: String, dockerHome: URL? = nil) {
        self.socketPath = socketPath
        self.dockerHome = dockerHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".docker", directoryHint: .isDirectory)
    }

    // MARK: - Pure

    /// Docker names a context's directory with the SHA-256 of the context name.
    public static func directoryName(for name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `meta.json` payload describing the endpoint.
    public static func metaJSON(name: String = DockerContext.name, socketPath: String) throws -> Data {
        let payload: [String: Any] = [
            "Name": name,
            "Metadata": ["Description": description],
            "Endpoints": ["docker": ["Host": "unix://\(socketPath)", "SkipTLSVerify": false]],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Filesystem

    public var metaDirectory: URL {
        dockerHome.appending(path: "contexts/meta/\(Self.directoryName(for: Self.name))", directoryHint: .isDirectory)
    }

    private var configURL: URL {
        dockerHome.appending(path: "config.json", directoryHint: .notDirectory)
    }

    /// Creates or refreshes the context. The empty TLS directory is required — the CLI refuses a
    /// context without one.
    public func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: metaDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dockerHome.appending(path: "contexts/tls/\(Self.directoryName(for: Self.name))/docker",
                                     directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        try Self.metaJSON(socketPath: socketPath)
            .write(to: metaDirectory.appending(path: "meta.json", directoryHint: .notDirectory), options: .atomic)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: metaDirectory.appending(path: "meta.json", directoryHint: .notDirectory).path)
    }

    /// Selects the context, preserving every other setting in `config.json`.
    public func makeCurrent() throws {
        try FileManager.default.createDirectory(at: dockerHome, withIntermediateDirectories: true)
        var config = readConfig()
        config["currentContext"] = Self.name
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)
    }

    /// Restores whatever context was selected before, or clears the selection.
    public func resign(to previous: String?) throws {
        var config = readConfig()
        if let previous { config["currentContext"] = previous } else { config.removeValue(forKey: "currentContext") }
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)
    }

    public func remove() throws {
        try? FileManager.default.removeItem(at: metaDirectory)
        if currentContext == Self.name { try resign(to: nil) }
    }

    /// The context the Docker CLI would use right now. `DOCKER_HOST` overrides contexts entirely,
    /// so it's reported as its own value — otherwise Crane would claim to be active while the
    /// user's shell quietly points somewhere else.
    public var currentContext: String? {
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], !host.isEmpty {
            return "DOCKER_HOST=\(host)"
        }
        return readConfig()["currentContext"] as? String
    }

    public var isCurrent: Bool { currentContext == Self.name }

    private func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
