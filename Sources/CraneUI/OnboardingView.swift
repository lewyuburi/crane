import CraneCore
import EngineControl
import SwiftUI

/// First run: say plainly what will be installed, then install it.
///
/// No wizard pages. Four binaries and two launch agents, all under Application Support and none
/// needing an admin password — that's short enough to just show.
public struct OnboardingView: View {
    @Environment(EngineModel.self) private var model

    public init() {}

    private var isWorking: Bool { model.phase == .working }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    ForEach(StackManifest.current.artifacts, id: \.component) { artifact in
                        ComponentRow(artifact: artifact, progress: model.progress[artifact.component])
                    }
                } header: {
                    Text("Crane will install")
                } footer: {
                    Text("Everything lands in ~/Library/Application Support/Crane. "
                         + "Crane also adds two login items so the engine is running when you need it.")
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
            // A single literal, not a concatenation: SwiftUI only applies Markdown — the code
            // ticks around `docker` — to literals.
            Text("Crane runs Apple's container runtime behind a Docker-compatible socket, so `docker`, Compose, Testcontainers and Dev Containers all work against it.")
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
                Task { await model.provision() }
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
            // Determinate only while bytes move; the other phases are too quick to measure and a
            // spinner tells the truth about them.
            ProgressView(value: progress?.fraction ?? 0).frame(width: 90)
        default:
            ProgressView().controlSize(.small)
        }
    }
}
