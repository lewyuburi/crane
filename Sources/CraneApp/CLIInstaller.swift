import Foundation

/// Installs the `crane` command-line tool (bundled inside Crane.app) onto the user's PATH by
/// symlinking it into /usr/local/bin — like VS Code's "Install 'code' command" or OrbStack's `orb`.
enum CLIInstaller {
    static let symlinkPath = "/usr/local/bin/crane"

    enum Status: Equatable {
        case unavailable      // running unbundled (e.g. `swift run`) — no CLI to install
        case notInstalled
        case installed
        case conflict(String) // a `crane` exists on PATH pointing somewhere else
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

    static var status: Status {
        guard let bundled = bundledCLI else { return .unavailable }
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath) else {
            return FileManager.default.fileExists(atPath: symlinkPath) ? .conflict(symlinkPath) : .notInstalled
        }
        return dest == bundled.path ? .installed : .conflict(dest)
    }

    /// Symlink the bundled CLI onto PATH. Tries a plain symlink, falling back to an admin prompt
    /// when /usr/local/bin isn't user-writable (the common case on a fresh Mac).
    static func install() throws {
        guard let src = bundledCLI else { throw InstallError.unavailable }
        let fm = FileManager.default
        do {
            try? fm.removeItem(atPath: symlinkPath)
            try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: src.path)
        } catch {
            try installWithAdmin(src: src.path)
        }
    }

    static func uninstall() throws {
        let fm = FileManager.default
        if fm.isDeletableFile(atPath: symlinkPath), (try? fm.removeItem(atPath: symlinkPath)) != nil { return }
        let osa = "do shell script \"rm -f '\(symlinkPath)'\" with administrator privileges"
        try runOsascript(osa)
    }

    private static func installWithAdmin(src: String) throws {
        let dir = (symlinkPath as NSString).deletingLastPathComponent
        let shell = "mkdir -p '\(dir)' && ln -sf '\(src)' '\(symlinkPath)'"
        try runOsascript("do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges")
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
