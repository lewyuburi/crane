import EngineControl
import SwiftUI

/// The handful of constants every view shares.
///
/// Crane's look is native on purpose — system materials, system type — but consistent spacing
/// and one status vocabulary are what keep it from looking like a settings dialog.
public enum Metric {
    /// The 4-point rhythm everything snaps to.
    public static let tight: CGFloat = 6
    public static let snug: CGFloat = 10
    public static let regular: CGFloat = 16
    public static let loose: CGFloat = 24
    public static let section: CGFloat = 32

    public static let cardRadius: CGFloat = 12
    /// Comfortable reading width for onboarding and explanatory copy.
    public static let proseWidth: CGFloat = 480
}

public extension Diagnostic.Severity {
    var tint: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .blocking: return .red
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        }
    }
}

public extension EngineComponent {
    var symbol: String {
        switch self {
        case .runtime: return "cpu"
        case .socktainer: return "point.3.connected.trianglepath.dotted"
        case .docker: return "terminal"
        case .compose: return "square.stack.3d.up"
        }
    }
}

/// A grouped container with the app's standard padding and material.
public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// A hairline between rows that stops short of the card's edges.
public struct RowDivider: View {
    public init() {}
    public var body: some View {
        Divider().padding(.leading, Metric.regular)
    }
}
