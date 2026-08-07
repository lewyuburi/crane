import Foundation
import Testing

@testable import CraneCore

@Suite("Reconnection backoff")
struct BackoffTests {
    @Test("Delays grow geometrically and stop at the ceiling")
    func growsAndCaps() {
        var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(10), multiplier: 2)
        let delays = (0..<8).map { _ in backoff.next().seconds }
        #expect(delays.prefix(6).map { ($0 * 1000).rounded() } == [250, 500, 1000, 2000, 4000, 8000])
        #expect(delays.dropFirst(6).allSatisfy { $0 == 10 }, "must not climb past the ceiling")
    }

    @Test("A successful connection resets the schedule")
    func resets() {
        var backoff = Backoff(initial: .milliseconds(100), maximum: .seconds(5))
        _ = backoff.next(); _ = backoff.next(); _ = backoff.next()
        backoff.reset()
        #expect((backoff.next().seconds * 1000).rounded() == 100)
    }

    @Test("The first retry is fast enough to feel instant")
    func firstRetryIsQuick() {
        var backoff = Backoff()
        #expect(backoff.next().seconds <= 0.5,
                "a daemon restart should heal without the user noticing")
    }
}
