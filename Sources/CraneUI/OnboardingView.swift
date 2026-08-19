import CraneCore
import EngineControl
import SwiftUI

/// First run: install the engine, and optionally the Docker CLI pack.
///
/// One page, a grouped Form, a checkbox for the pack (hidden when another `docker` is on PATH).
public struct OnboardingView: View {
    @Environment(EngineModel.self) private var model
    @State private var includeCLI = true

    public init() {}

    private var isWorking: Bool { model.phase == .working }
    private var foreignDocker: String? { model.status?.foreignDockerPath }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    ForEach(StackManifest.current.engineArtifacts, id: \.component) { artifact in
                        ComponentRow(artifact: artifact, progress: model.progress[artifact.component])
                    }
                } header: {
                    Text("Crane will install")
                } footer: {
                    Text("Everything lands in ~/Library/Application Support/Crane. Crane also adds two login items so the engine is running when you need it.")
                }

                if foreignDocker == nil {
                    Section {
                        Toggle("Install Docker CLI and Compose", isOn: $includeCLI)
                            .toggleStyle(.checkbox)
                            .disabled(isWorking)
                    } footer: {
                        Text("Adds the official `docker` and `docker compose` commands. Open a new terminal window after setup.")
                    }
                } else {
                    Section {
                        LabeledContent("Docker CLI") {
                            Text("Already installed")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Found `docker` at \(foreignDocker ?? ""). Crane will register a `crane` context; turn on “Use Crane as the engine” later if you want that CLI to talk to Crane.")
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
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: Metric.snug) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Set up the container engine")
                .font(.largeTitle.weight(.semibold))
            Text("Crane runs Apple’s container runtime behind a Docker-compatible socket. The GUI talks to that socket. `docker` in Terminal is optional.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(.top, Metric.loose * 1.5)
        .padding(.horizontal, Metric.loose)
    }

    private var footer: some View {
        HStack {
            Text(CraneVersion.stackSummary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await model.provision(includeCLI: includeCLI && foreignDocker == nil) }
            } label: {
                Text(isWorking ? "Setting up…" : "Set up Crane")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Metric.loose)
        .background(.bar)
    }
}

private struct ComponentRow: View {
    let artifact: Artifact
    let progress: StackInstaller.Progress?

    var body: some View {
        LabeledContent {
            status
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Metric.tight) {
                        Text(artifact.component.displayName)
                        Text(artifact.version)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(artifact.component.purpose)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: artifact.component.symbol)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch progress?.phase {
        case .none:
            EmptyView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
        case .downloading:
            ProgressView(value: progress?.fraction ?? 0).frame(width: 90)
        default:
            ProgressView().controlSize(.small)
        }
    }
}

#Preview("Onboarding") {
    CranePreview.window(
        OnboardingView().environment(
            CranePreview.model(
                phase: .needsSetup,
                status: PreviewFixtures.engineStatus(runtime: false, running: false),
                fillWorkspace: false)),
        width: 900, height: 700)
}

#Preview("Onboarding · foreign CLI") {
    CranePreview.window(
        OnboardingView().environment(
            CranePreview.model(
                phase: .needsSetup,
                status: PreviewFixtures.engineStatus(runtime: false, running: false,
                                                     foreignDockerPath: "/usr/local/bin/docker"),
                fillWorkspace: false)),
        width: 900, height: 700)
}
