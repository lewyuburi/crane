import SwiftUI
import CraneKit

extension ContainerStatus {
    /// UI tint for the status dot/pill. Lives in the app layer so CraneKit stays UI-free.
    var tint: Color {
        switch self {
        case .running: return .green
        case .stopped: return .secondary
        case .created: return .orange
        case .unknown: return .gray
        }
    }
}
