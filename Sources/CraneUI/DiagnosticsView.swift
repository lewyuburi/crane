import CraneCore
import EngineControl
import SwiftUI

/// The stack's health, one row per thing that can be wrong, each with the button that fixes it.
///
/// This is the screen that earns trust: nothing here is a status light without a remedy, and the
/// remedies are the same calls onboarding makes.
public struct DiagnosticsView: View {
    @Environment(EngineModel.self) private var model
    @State private var repairing: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.loose) {
                header
                Card {
                    ForEach(Array(model.diagnostics.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { RowDivider() }
                        DiagnosticRow(check: check, isRepairing: repairing == check.id) {
                            await repair(check)
                        }
                    }
                }
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Text(CraneVersion.stackSummary)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(Metric.loose)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Engine")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metric.tight) {
            Text(model.phase == .ready ? "Everything is running" : "The engine needs attention")
                .font(.title2.weight(.semibold))
            Text(model.phase == .ready
                 ? "Docker-compatible tools can connect to this Mac."
                 : "Fix the items below to start containers.")
                .foregroundStyle(.secondary)
        }
    }

    private func repair(_ check: Diagnostic) async {
        guard let action = check.repair else { return }
        repairing = check.id
        defer { repairing = nil }
        await model.repair(action)
    }
}

private struct DiagnosticRow: View {
    let check: Diagnostic
    let isRepairing: Bool
    let repair: () async -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metric.snug) {
            Image(systemName: check.severity.symbol)
                .foregroundStyle(check.severity.tint)
                .accessibilityLabel(accessibilityStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).fontWeight(.medium)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metric.regular)
            if isRepairing {
                ProgressView().controlSize(.small)
            } else if check.repair != nil {
                Button("Fix") { Task { await repair() } }
            }
        }
        .padding(Metric.regular)
    }

    private var accessibilityStatus: String {
        switch check.severity {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .blocking: return "Blocked"
        }
    }
}
