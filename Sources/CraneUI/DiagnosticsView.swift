import CraneCore
import EngineControl
import SwiftUI

/// The stack's health, one row per thing that can be wrong, each with the button that fixes it.
///
/// A grouped `Form` — the same construction System Settings uses — so the rows align, the section
/// headers read as headers, and nothing here is a status light without a remedy.
public struct DiagnosticsView: View {
    @Environment(EngineModel.self) private var model
    @State private var repairing: String?

    public init() {}

    private var status: EngineStatus? { model.status }

    public var body: some View {
        Form {
            Section {
                ForEach(model.diagnostics) { check in
                    DiagnosticRow(check: check, isRepairing: repairing == check.id) {
                        await repair(check)
                    }
                }
            } header: {
                Text(model.phase == .ready ? "Everything is running" : "Needs attention")
            } footer: {
                if model.phase == .ready {
                    Text("Docker-compatible tools on this Mac talk to Crane.")
                } else {
                    Text("Containers can't run until the blocking items are fixed.")
                }
            }

            Section("Stack") {
                DetailRow("Crane", CraneVersion.current)
                ForEach(StackManifest.current.artifacts, id: \.component) { artifact in
                    DetailRow(artifact.component.displayName, artifact.version)
                }
                LabeledContent("Docker socket") {
                    Text(model.engine.socketPath)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Engine")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Re-check", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button("Repair everything", systemImage: "wrench.adjustable") {
                    Task { await model.provision() }
                }
                .disabled(model.phase == .working)
            }
        }
        .task { await model.refresh() }
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
        LabeledContent {
            if isRepairing {
                ProgressView().controlSize(.small)
            } else if check.repair != nil {
                Button("Fix") { Task { await repair() } }
                    .buttonStyle(.bordered)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title)
                    Text(check.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: check.severity.symbol)
                    .foregroundStyle(check.severity.tint)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
