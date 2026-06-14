/// The single source of truth for Crane's marketing version.
///
/// `release.yml` stamps `current` from the pushed git tag before building, so every release's CLI
/// `--version` and the app's `CFBundleShortVersionString` (set by `bundle.sh` from this same value)
/// stay in lock-step. The committed value is the dev/default fallback for non-release builds.
public enum CraneVersion {
    public static let current = "0.1.4"
}
