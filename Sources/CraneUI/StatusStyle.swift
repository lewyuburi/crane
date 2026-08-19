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
}

/// Bytes in the units people actually read.
public func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}
