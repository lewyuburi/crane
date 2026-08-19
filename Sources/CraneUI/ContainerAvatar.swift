import CraneCore
import SwiftUI

/// The tile that identifies a container in a list: image glyph, with its state as a dot on the
/// corner.
///
/// One shape carrying both facts means a row scans in a single glance — which image, and whether
/// it's up — instead of two separate things to read.
public struct ContainerAvatar: View {
    let image: String
    let state: Container.RunState
    let health: Container.Health?
    var size: CGFloat = 26

    public init(image: String, state: Container.RunState, health: Container.Health? = nil,
                size: CGFloat = 26) {
        self.image = image
        self.state = state
        self.health = health
        self.size = size
    }

    private var appearance: ImageAppearance { ImageAppearance.of(image: image) }

    private var tint: Color {
        Color(hue: appearance.hue, saturation: 0.62, brightness: 0.88)
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let symbol = appearance.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(appearance.monogram)
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            // The dot sits half-off the tile so it stays legible whatever the tile's colour is.
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(dotColor)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .overlay(Circle().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: size * 0.07))
                    .offset(x: size * 0.12, y: size * 0.12)
            }
            .accessibilityLabel("\(ImageAppearance.repositoryName(from: image)), \(state.label)")
    }

    private var dotColor: Color {
        health.map(\.tint) ?? state.tint
    }
}

#Preview("Avatars") {
    HStack(spacing: 16) {
        ContainerAvatar(image: "nginx:alpine", state: .running, health: .healthy, size: 44)
        ContainerAvatar(image: "postgres:17", state: .running, health: .starting, size: 44)
        ContainerAvatar(image: "redis:7", state: .exited, size: 44)
        ContainerAvatar(image: "scratch-app", state: .created, size: 44)
    }
    .padding(24)
}
