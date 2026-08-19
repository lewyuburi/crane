import CraneCore
import EngineControl
import SwiftUI

/// Shared host for `#Preview` so every canvas uses the same seeded engine and skips live I/O.
enum CranePreview {
    @MainActor
    static func model(
        phase: EngineModel.Phase = .ready,
        status: EngineStatus = PreviewFixtures.engineStatus(cliPack: true),
        fillWorkspace: Bool = true
    ) -> EngineModel {
        let model = EngineModel()
        model.seedPreview(status: status, phase: phase)
        if fillWorkspace {
            model.workspace.seed(
                containers: PreviewFixtures.containers,
                images: PreviewFixtures.images,
                volumes: PreviewFixtures.volumes,
                networks: PreviewFixtures.networks)
        } else {
            model.workspace.seed()
        }
        return model
    }

    static func window<Content: View>(_ content: Content, width: CGFloat = 1180, height: CGFloat = 780) -> some View {
        content.frame(minWidth: width, minHeight: height)
            .frame(width: width, height: height)
    }
}
