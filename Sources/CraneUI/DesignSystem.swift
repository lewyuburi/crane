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

/// One row in a grouped Form: label on the left, value on the right.
///
/// Every detail pane uses this so Status, Ports, Engine versions and Stats totals
/// read as the same list — System Settings' `LabeledContent`, not a mix of tables and tints.
public struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool

    public init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    public var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Filter field that belongs to a list column. `.searchable(placement: .toolbar)` on a
/// `NavigationSplitView` content pane lands in the unified titlebar next to the detail
/// actions, which is how Filter showed up beside the trash on Images and Volumes.
struct ColumnFilter: View {
    @Binding var text: String
    var prompt: String = "Filter"

    var body: some View {
        HStack(spacing: Metric.tight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, Metric.snug)
        .padding(.vertical, 6)
    }
}
