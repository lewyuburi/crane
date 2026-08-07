import EngineControl
import SwiftUI

/// Spacing tokens. Everything else about Crane's look comes from AppKit and SwiftUI themselves —
/// `Form`, `Section`, `LabeledContent`, `Table` and Liquid Glass already know what a macOS app
/// looks like, and hand-drawn cards only manage to look like a worse version of them.
public enum Metric {
    public static let tight: CGFloat = 6
    public static let snug: CGFloat = 10
    public static let regular: CGFloat = 16
    public static let loose: CGFloat = 24

    /// Comfortable reading width for explanatory copy.
    public static let proseWidth: CGFloat = 460
    /// Detail panes stop growing here so text doesn't stretch across a wide window.
    public static let detailWidth: CGFloat = 720
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
        case .docker: return "apple.terminal"
        case .compose: return "square.stack.3d.up"
        }
    }
}

/// A value shown next to a label, monospaced and selectable — the shape most of Crane's detail
/// rows take. Wraps `LabeledContent` so every one of them aligns identically.
public struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = true
    var tint: Color?

    public init(_ label: String, _ value: String, monospaced: Bool = true, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.tint = tint
    }

    public var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
