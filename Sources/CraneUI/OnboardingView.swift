import CraneCore
import EngineControl
import SwiftUI

/// First run: say plainly what will be installed, then install it.
///
/// No wizard pages. Crane needs four binaries and two launch agents, all under Application
/// Support and none of them requiring an admin password — that is short enough to just show.
public struct OnboardingView: View {
    @Environment(EngineModel.self) private var model

    public init() {}

    private var manifest: StackManifest { StackManifest.current }
    private var isWorking: Bool { model.phase == .working }

    public var body: some View {
        VStack(spacing: Metric.loose) {
            Spacer(minLength: 0)

            VStack(spacing: Metric.snug) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                Text("Set up the container engine")
                    .font(.largeTitle.weight(.semibold))
                Text("Crane installs and supervises everything below. It all lives in your "
                     + "Library folder — no admin password, nothing added to the system.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Metric.proseWidth)
            }

            Card {
                ForEach(Array(EngineComponent.allCases.enumerated()), id: \.element) { index, component in
                    if index > 0 { RowDivider() }
                    ComponentRow(component: component,
                                 version: manifest.artifact(for: component).version,
                                 progress: model.progress[component])
                }
            }
            .frame(maxWidth: Metric.proseWidth + 80)

            VStack(spacing: Metric.snug) {
                Button {
                    Task { await model.provision() }
                } label: {
                    Text(isWorking ? "Setting up…" : "Set up Crane")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
                .keyboardShortcut(.defaultAction)

                if let failure = model.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: Metric.proseWidth)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Metric.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComponentRow: View {
    let component: EngineComponent
    let version: String
    let progress: StackInstaller.Progress?

    var body: some View {
        HStack(spacing: Metric.snug) {
            Image(systemName: component.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Metric.tight) {
                    Text(component.displayName).fontWeight(.medium)
                    Text(version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(component.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Metric.regular)
            status
        }
        .padding(Metric.regular)
    }

    @ViewBuilder
    private var status: some View {
        switch progress?.phase {
        case .none:
            EmptyView()
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            // A determinate bar only while bytes are moving; the other phases are too quick to
            // measure and a spinner tells the truth about them.
            ProgressView(value: progress?.fraction ?? 0)
                .frame(width: 90)
            .progressViewStyle(.linear)
        default:
            ProgressView().controlSize(.small)
        }
    }
}
