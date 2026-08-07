import Foundation
import Testing

@testable import DockerAPI

@Suite("NDJSON line splitting")
struct LineSplitterTests {
    private func lines(_ chunks: [String]) -> [String] {
        var splitter = LineSplitter()
        var out: [String] = []
        for chunk in chunks {
            out += splitter.push(Data(chunk.utf8)).map { String(decoding: $0, as: UTF8.self) }
        }
        if let tail = splitter.finish() { out.append(String(decoding: tail, as: UTF8.self)) }
        return out
    }

    @Test("Splits complete lines")
    func splitsLines() {
        #expect(lines(["a\nb\nc\n"]) == ["a", "b", "c"])
    }

    @Test("Carries a partial line across chunk boundaries")
    func carriesAcrossChunks() {
        #expect(lines([#"{"Type":"cont"#, #"ainer"}"# + "\n"]) == [#"{"Type":"container"}"#])
    }

    @Test("Emits a trailing line without a newline only on finish")
    func flushesTail() {
        var splitter = LineSplitter()
        #expect(splitter.push(Data("no newline".utf8)).isEmpty)
        #expect(splitter.finish().map { String(decoding: $0, as: UTF8.self) } == "no newline")
    }

    @Test("Drops the empty keep-alive lines the daemon sends")
    func dropsBlankLines() {
        #expect(lines(["a\n\n\nb\n"]) == ["a", "b"])
    }

    @Test("A peer that never sends a newline can't grow the buffer without bound")
    func enforcesLimit() {
        var splitter = LineSplitter(limit: 8)
        #expect(splitter.push(Data(String(repeating: "x", count: 64).utf8)).isEmpty)
        #expect(splitter.finish() == nil)
    }
}
