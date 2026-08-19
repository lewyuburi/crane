import Foundation

/// Everything that can go wrong between Crane and the daemon.
///
/// The distinction that matters to the UI is *whose* fault it is: `notRunning` is a stack
/// problem the Engine pane can repair, `api` is a request the daemon rejected, and
/// `unsupported` is a capability Apple's runtime genuinely lacks — never dressed up as success.
public enum DockerError: Error, LocalizedError, Equatable, Sendable {
    /// No socket file, or nothing accepting connections on it.
    case notRunning(socket: String)
    /// The daemon answered with a non-2xx status and (usually) a `{"message": …}` body.
    case api(status: UInt, message: String)
    /// The endpoint exists in the Docker API but this stack can't implement it.
    case unsupported(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case let .notRunning(socket):
            return "The container engine isn't running (no daemon on \(socket))."
        case let .api(status, message):
            return message.isEmpty ? "The engine returned HTTP \(status)." : message
        case let .unsupported(what):
            return "\(what) isn't supported by Apple's container runtime."
        case let .decoding(detail):
            return "Unexpected response from the engine: \(detail)."
        }
    }

    /// Maps a failed response into an error, preferring the daemon's own message.
    /// Pure so the mapping is unit-tested without a socket.
    public static func from(status: UInt, body: Data) -> DockerError {
        struct Message: Decodable { let message: String }
        let decoded = try? JSONDecoder().decode(Message.self, from: body)
        let fallback = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .api(status: status, message: decoded?.message ?? fallback)
    }
}
