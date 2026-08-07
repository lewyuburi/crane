import Foundation

/// Exponential backoff with a ceiling.
///
/// Used when the event feed loses the daemon: retrying every 100 ms would spin the CPU while
/// socktainer restarts, and retrying every 30 s would make a blip feel like an outage. Pure and
/// deterministic so the schedule is a tested decision rather than a guess.
public struct Backoff: Sendable, Equatable {
    public let initial: Duration
    public let maximum: Duration
    public let multiplier: Double

    private var attempt = 0

    public init(initial: Duration = .milliseconds(250), maximum: Duration = .seconds(10),
                multiplier: Double = 2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
    }

    /// The delay to wait before the next attempt, growing until it hits `maximum`.
    public mutating func next() -> Duration {
        let factor = pow(multiplier, Double(attempt))
        attempt += 1
        let seconds = min(initial.seconds * factor, maximum.seconds)
        return .seconds(seconds)
    }

    /// Called after a successful connection: the next failure starts over from `initial`.
    public mutating func reset() {
        attempt = 0
    }
}

extension Duration {
    /// The duration in seconds as a `Double` — `components` is (seconds, attoseconds).
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
