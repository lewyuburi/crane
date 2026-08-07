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
                NavigationStack { DiagnosticsView() }
            }
        }
        .task { await model.refresh() }
        .task {
            // The event feed lives as long as the window does: it's what keeps the container
            // list current without a single poll.
            model.startWatching()
        }
    }
}
