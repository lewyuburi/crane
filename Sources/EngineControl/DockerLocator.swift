import Foundation

/// Finds `docker` the way a login shell would: first executable named `docker` on `PATH`.
///
/// Crane only treats a binary as *foreign* when it isn't the one in Crane's own `bin/`. That
/// is what lets the CLI pack occupy PATH without the engine thinking it has to step aside.
public enum DockerLocator: Sendable {
    /// Absolute path of the first `docker` on `PATH`, or nil if there isn't one.
    public static func resolve(
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        guard let pathEnvironment else { return nil }
        let fm = FileManager.default
        for directory in pathEnvironment.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appending(path: "docker", directoryHint: .notDirectory)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL.path(percentEncoded: false)
            }
        }
        return nil
    }

    /// Path of a `docker` that Crane did not install, or nil if none / it's Crane's.
    public static func foreignPath(
        craneBin: URL,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        guard let resolved = resolve(pathEnvironment: pathEnvironment) else { return nil }
        let parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().standardizedFileURL
        if parent.path(percentEncoded: false) == craneBin.standardizedFileURL.path(percentEncoded: false) {
            return nil
        }
        return resolved
    }
}
