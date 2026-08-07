import Foundation

/// Where the Docker-compatible daemon listens.
///
/// Crane supervises socktainer, which binds a fixed path under the user's home
/// (`~/.socktainer/container.sock` — see `SocketUtility` in socktainer). The path is not
/// configurable there, so it is a constant here rather than a setting.
public struct DockerSocket: Sendable, Hashable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public static let socktainer = DockerSocket(
        path: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".socktainer/container.sock", directoryHint: .notDirectory).path(percentEncoded: false)
    )

    /// Whether the socket file is present. Cheap enough to call before every connect attempt —
    /// it turns "connection refused" into a precise "the daemon isn't running".
    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The `http+unix://` URL AsyncHTTPClient expects: the socket path percent-encoded into the
    /// host component, then the request path. Pure, so the encoding is unit-tested.
    public func url(_ requestPath: String, query: [URLQueryItem] = []) -> String {
        let host = Self.percentEncodedHost(path)
        var url = "http+unix://\(host)\(requestPath.hasPrefix("/") ? "" : "/")\(requestPath)"
        if !query.isEmpty {
            var components = URLComponents()
            components.queryItems = query
            // `+` is a literal in a socket query value (e.g. a filter with a space would otherwise
            // round-trip wrong); URLComponents leaves it alone, so encode it ourselves.
            let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            if !encoded.isEmpty { url += "?\(encoded)" }
        }
        return url
    }

    /// Percent-encodes every character a URL host can't carry — in practice the path separators.
    static func percentEncodedHost(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
