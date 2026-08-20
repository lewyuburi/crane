import EngineControl
import Foundation

/// Crane's own version, plus the stack it was tested against.
///
/// `release.yml` stamps `current` from the pushed tag, so `crane --version`, the app's
/// `CFBundleShortVersionString` and the About panel can't drift apart.
public enum CraneVersion {
    public static let current = "2.0.6"

    /// What the UI shows as one unit — Crane and its engine are versioned together.
    public static var stackSummary: String {
        let manifest = StackManifest.current
        return "Crane \(current) · container \(manifest.runtime.version) · socktainer \(manifest.socktainer.version)"
    }
}
