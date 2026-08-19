import CraneCore
import SwiftUI

/// Chooses what the window shows, based on the one thing that decides it: the engine's phase.
public struct RootView: View {
    @Environment(EngineModel.self) private var model

    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .checking:
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsSetup, .working:
                OnboardingView()
            case .ready:
                WorkspaceView()
            case .needsAttention:
                NavigationStack { EngineView() }
            }
        }
        .task { if !model.previewLocked { await model.refresh() } }
        .task {
            // The event feed lives as long as the window does: it's what keeps the container
            // list current without a single poll.
            if !model.previewLocked { model.startWatching() }
        }
    }
}

#Preview("App · workspace") {
    CranePreview.window(RootView().environment(CranePreview.model()))
}

#Preview("App · onboarding") {
    CranePreview.window(
        RootView().environment(
            CranePreview.model(
                phase: .needsSetup,
                status: PreviewFixtures.engineStatus(runtime: false, running: false, contextCurrent: nil),
                fillWorkspace: false)))
}

#Preview("App · needs attention") {
    CranePreview.window(
        RootView().environment(
            CranePreview.model(
                phase: .needsAttention,
                status: PreviewFixtures.engineStatus(running: false),
                fillWorkspace: false)))
}
