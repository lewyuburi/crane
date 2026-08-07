import Foundation

/// Splits a byte stream into newline-delimited chunks across arbitrary buffer boundaries.
///
/// The daemon streams NDJSON for `/events`, `/images/create` progress and `/stats`: one JSON
/// document per line, arriving in chunks that split anywhere. Keeping the carry-over in a value
/// type (rather than inside the networking code) is what makes stream decoding testable without
/// a socket.
public struct LineSplitter: Sendable {
    private var carry = Data()

    /// Bytes buffered without a newline before we give up and flush. Guards against a peer that
    /// streams megabytes without a delimiter; 1 MiB is far above any real event or stats frame.
    public let limit: Int

    public init(limit: Int = 1 << 20) {
        self.limit = limit
    }

    /// Feeds a chunk and returns the complete lines it closed. Empty lines are dropped —
    /// the daemon uses them as keep-alives.
    public mutating func push(_ chunk: Data) -> [Data] {
        carry.append(chunk)
        var lines: [Data] = []
        while let newline = carry.firstIndex(of: 0x0A) {
            let line = carry[carry.startIndex..<newline]
            carry = carry[carry.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if carry.count > limit { carry.removeAll(keepingCapacity: false) }
        return lines
    }

    /// Whatever is left when the stream ends, if it isn't empty (a final line without newline).
    public mutating func finish() -> Data? {
        defer { carry.removeAll(keepingCapacity: false) }
        return carry.isEmpty ? nil : Data(carry)
    }
}
