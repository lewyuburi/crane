import CraneCore
import SwiftUI

/// How container state reads at a glance: one dot, one vocabulary, everywhere.
public extension Container.RunState {
    var tint: Color {
        switch self {
        case .running: return .green
        case .restarting: return .yellow
        case .paused: return .orange
        case .created: return .blue
        case .exited, .dead: return .secondary
        case .unknown: return .secondary
        }
    }

    var label: String {
        switch self {
        case .created: return "Created"
        case .running: return "Running"
        case .paused: return "Paused"
        case .restarting: return "Restarting"
        case .exited: return "Exited"
        case .dead: return "Dead"
        case .unknown: return "Unknown"
        }
    }
}

public extension Container.Health {
    var tint: Color {
        switch self {
        case .healthy: return .green
        case .starting: return .yellow
        case .unhealthy: return .red
        }
    }

    var symbol: String {
        switch self {
        case .healthy: return "heart.fill"
        case .starting: return "heart"
        case .unhealthy: return "heart.slash.fill"
        }
    }
}

/// The status dot used in every list. A ring around it keeps it visible against selection.
public struct StatusDot: View {
    let state: Container.RunState
    let health: Container.Health?

    public init(state: Container.RunState, health: Container.Health? = nil) {
        self.state = state
        self.health = health
    }

    public var body: some View {
        Circle()
            .fill(health?.tint ?? state.tint)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke((health?.tint ?? state.tint).opacity(0.25), lineWidth: 3))
            .accessibilityLabel(health.map { "\(state.label), \($0.rawValue)" } ?? state.label)
    }
}

/// A small capsule for ports, tags and counts.
public struct Pill: View {
    let text: String
    var tint: Color = .secondary

    public init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Bytes in the units people actually read.
public func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}
