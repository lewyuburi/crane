import Foundation

/// Installs the `crane` command-line tool (bundled inside Crane.app) onto the user's PATH by
/// symlinking it into /usr/local/bin — like VS Code's "Install 'code' command" or OrbStack's `orb`.
///
/// The same binary is a multi-call tool: symlinked as `docker` / `docker-compose` it serves the
/// Docker compatibility shim. Those aliases are opt-in and conflict-aware so they never silently
/// shadow a real Docker install.
enum CLIInstaller {
    static let symlinkPath = "/usr/local/bin/crane"
    static let dockerAliasPaths = ["/usr/local/bin/docker", "/usr/local/bin/docker-compose"]

    enum Status: Equatable {
        case unavailable      // running unbundled (e.g. `swift run`) — no CLI to install
        case notInstalled
        case installed
        case conflict(String) // a binary already exists on PATH pointing somewhere else
    }

    enum InstallError: LocalizedError {
        case unavailable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The crane CLI is only available from the packaged app."
            case .failed(let m): return m
            }
        }
    }

    /// The `crane` binary shipped in Crane.app/Contents/Helpers, if present.
    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/crane")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - crane

    static var status: Status { status(of: [symlinkPath]) }

    /// Symlink the bundled CLI onto PATH. Tries a plain symlink, falling back to an admin prompt
    /// when /usr/local/bin isn't user-writable (the common case on a fresh Mac).
    static func install() throws { try link([symlinkPath]) }
    static func uninstall() throws { try unlink([symlinkPath]) }

    // MARK: - docker / docker-compose aliases

    /// `.installed` only when *both* aliases point at our binary; `.conflict` if either points
    /// elsewhere (e.g. a real Docker Desktop install) so we can warn instead of clobbering.
    static var dockerAliasStatus: Status { status(of: dockerAliasPaths) }

    static func installDockerAliases() throws { try link(dockerAliasPaths) }
    static func uninstallDockerAliases() throws { try unlink(dockerAliasPaths) }

    // MARK: - shared symlink machinery

    private static func status(of paths: [String]) -> Status {
        guard let bundled = bundledCLI else { return .unavailable }
        let fm = FileManager.default
        var allInstalled = true
        for path in paths {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else {
                if fm.fileExists(atPath: path) { return .conflict(path) }
                allInstalled = false
                continue
            }
            if dest != bundled.path { return .conflict(dest) }
        }
        return allInstalled ? .installed : .notInstalled
    }

    private static func link(_ paths: [String]) throws {
        guard let src = bundledCLI else { throw InstallError.unavailable }
        let fm = FileManager.default
        do {
            for path in paths {
                try? fm.removeItem(atPath: path)
                try fm.createSymbolicLink(atPath: path, withDestinationPath: src.path)
            }
        } catch {
            let dir = (paths[0] as NSString).deletingLastPathComponent
            let cmds = ["mkdir -p '\(dir)'"] + paths.map { "ln -sf '\(src.path)' '\($0)'" }
            try runAdminShell(cmds.joined(separator: " && "))
        }
    }

    private static func unlink(_ paths: [String]) throws {
        let fm = FileManager.default
        let needAdmin = paths.contains { fm.fileExists(atPath: $0) && !fm.isDeletableFile(atPath: $0) }
        if !needAdmin {
            for path in paths { try? fm.removeItem(atPath: path) }
            return
        }
        try runAdminShell(paths.map { "rm -f '\($0)'" }.joined(separator: "; "))
    }

    private static func runAdminShell(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\"", with: "\\\"")
        try runOsascript("do shell script \"\(escaped)\" with administrator privileges")
    }

    private static func runOsascript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // osascript exits 1 / -128 when the user cancels the auth dialog.
            throw InstallError.failed(msg.contains("-128") || msg.isEmpty ? "Authorization cancelled." : msg)
        }
    }
}
