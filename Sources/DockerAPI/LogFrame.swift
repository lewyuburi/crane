import Foundation

/// One chunk of container output, tagged with the stream it came from.
public struct LogChunk: Sendable, Equatable {
    public enum Stream: UInt8, Sendable { case stdin = 0, stdout = 1, stderr = 2 }

    public let stream: Stream
    public let text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Decodes Docker's multiplexed log framing.
///
/// Without a TTY the daemon interleaves stdout and stderr on one connection, each chunk prefixed
/// by an 8-byte header: `[stream, 0, 0, 0, big-endian length]`. With a TTY there is no framing at
/// all — the bytes are the output. Getting this wrong shows control bytes in the log console, so
/// it is a value type with its own tests rather than logic buried in a view.
public struct LogFrameDecoder: Sendable {
    private let multiplexed: Bool
    private var carry = Data()

    /// - Parameter multiplexed: false when the container was created with a TTY.
    public init(multiplexed: Bool = true) {
        self.multiplexed = multiplexed
    }

    public mutating func push(_ chunk: Data) -> [LogChunk] {
        guard multiplexed else {
            return chunk.isEmpty ? [] : [LogChunk(stream: .stdout, text: String(decoding: chunk, as: UTF8.self))]
        }
        carry.append(chunk)
        var out: [LogChunk] = []
        while carry.count >= 8 {
            let header = carry.prefix(8)
            let length = header.dropFirst(4).reduce(0) { ($0 << 8) | Int($1) }
            guard carry.count >= 8 + length else { break }   // wait for the rest of the payload
            let payload = carry.dropFirst(8).prefix(length)
            carry = carry.dropFirst(8 + length)
            let stream = LogChunk.Stream(rawValue: header[header.startIndex]) ?? .stdout
            out.append(LogChunk(stream: stream, text: String(decoding: payload, as: UTF8.self)))
        }
        return out
    }
}
