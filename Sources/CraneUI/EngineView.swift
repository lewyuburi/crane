import CraneCore
import EngineControl
import SwiftUI

/// Engine health and the optional Docker CLI pack.
///
/// A grouped Form in the System Settings shape: health rows with a Fix, then a Docker CLI
/// section whose control matches the decision (switch, button, or an explanation).
public struct EngineView: View {
    @Environment(EngineModel.self) private var model
    @State private var repairing: String?

    public init() {}

    public var body: some View {
        Form {
            statusSection
            dockerCLISection
            stackSection
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
        .task { if !model.previewLocked { await model.refresh() } }
    }

    private var statusSection: some View {
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
                Text("The GUI talks to Crane’s socket. `docker` in Terminal is separate — see Docker CLI below.")
            } else {
                Text("Containers can’t run until the blocking items are fixed.")
            }
        }
    }

    @ViewBuilder
    private var dockerCLISection: some View {
        if let status = model.status {
            Section {
                if status.cliPackBlocked, let path = status.foreignDockerPath {
                    foreignCLI(status: status, path: path)
                } else if status.cliPackInstalled {
                    installedCLI(status: status)
                } else {
                    missingCLI
                }
            } header: {
                Text("Docker CLI")
            } footer: {
                dockerFooter(status)
            }
        }
    }

    private func foreignCLI(status: EngineStatus, path: String) -> some View {
        Group {
            LabeledContent("Installed CLI") {
                Text(path)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            useCraneToggle(status)
        }
    }

    private func installedCLI(status: EngineStatus) -> some View {
        Group {
            DetailRow("Docker", StackManifest.current.docker.version, monospaced: true)
            DetailRow("Compose", StackManifest.current.compose.version, monospaced: true)
            useCraneToggle(status)
        }
    }

    private func useCraneToggle(_ status: EngineStatus) -> some View {
        Toggle("Use Crane as the engine", isOn: useCraneBinding)
            .disabled(status.isDockerHostOverridden || model.phase == .working)
    }

    private var missingCLI: some View {
        LabeledContent {
            if model.cliBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") { Task { await model.provisionCLI() } }
                    .buttonStyle(.bordered)
                    .disabled(model.phase == .working)
            }
        } label: {
            Text("Official CLI and Compose")
        }
    }

    private func dockerFooter(_ status: EngineStatus) -> Text {
        if status.isDockerHostOverridden {
            Text("Your shell sets \(status.contextCurrent ?? "DOCKER_HOST"), which overrides Docker contexts. Unset it to use Crane.")
        } else if status.cliPackBlocked {
            Text("Crane won’t replace that binary. Switching the toggle selects the `crane` context for the CLI you already have.")
        } else if status.cliPackInstalled {
            Text("Open a new terminal window if `docker` isn’t found yet. Crane prepends its bin directory in ~/.zprofile.")
        } else {
            Text("Installs the pinned Docker CLI and Compose into Crane’s folder and adds them to PATH.")
        }
    }

    private var stackSection: some View {
        Section("Stack") {
            DetailRow("Crane", CraneVersion.current, monospaced: true)
            ForEach(StackManifest.current.engineArtifacts, id: \.component) { artifact in
                DetailRow(artifact.component.displayName, artifact.version, monospaced: true)
            }
            DetailRow("Docker socket", model.engine.socketPath, monospaced: true)
        }
    }

    private var useCraneBinding: Binding<Bool> {
        Binding(
            get: { model.status?.isContextCurrent ?? false },
            set: { enabled in Task { await model.setUseCraneAsEngine(enabled) } }
        )
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

#Preview("Engine · no CLI") {
    CranePreview.window(
        NavigationStack { EngineView() }
            .environment(CranePreview.model(status: PreviewFixtures.engineStatus())),
        width: 640, height: 720)
}

#Preview("Engine · foreign CLI") {
    CranePreview.window(
        NavigationStack { EngineView() }
            .environment(CranePreview.model(
                status: PreviewFixtures.engineStatus(foreignDockerPath: "/usr/local/bin/docker",
                                                     contextCurrent: "desktop-linux"))),
        width: 640, height: 720)
}

#Preview("Engine · pack installed") {
    CranePreview.window(
        NavigationStack { EngineView() }
            .environment(CranePreview.model(status: PreviewFixtures.engineStatus(cliPack: true))),
        width: 640, height: 720)
}
