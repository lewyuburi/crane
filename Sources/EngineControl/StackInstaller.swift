import AppleContainer
import CryptoKit
import Foundation

public enum EngineError: Error, LocalizedError, Equatable {
    case download(String)
    case digestMismatch(component: EngineComponent, expected: String, actual: String)
    case untrustedPackage(String)
    case unpack(String)
    case launchd(String)
    /// A Docker CLI Crane didn't install is already on PATH; the pack must not replace it.
    case cliPackBlocked(String)

    public var errorDescription: String? {
        switch self {
        case let .download(detail):
            return detail
        case let .digestMismatch(component, expected, actual):
            return "\(component.displayName) doesn't match its expected checksum "
                + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…). Nothing was installed."
        case let .untrustedPackage(detail):
            return "The downloaded package isn't signed by the expected publisher: \(detail)"
        case let .unpack(detail):
            return detail
        case let .launchd(detail):
            return detail
        case let .cliPackBlocked(path):
            return "A Docker CLI is already installed at \(path). Crane won't replace it — "
                + "point that CLI at Crane with the crane Docker context."
        }
    }
}

/// Downloads, verifies and lays out the blessed stack.
///
/// Two rules, both non-negotiable: nothing is unpacked before its SHA-256 matches the manifest,
/// and Apple's package must additionally carry Apple's own Developer ID signature. A version is
/// only linked into `bin/` once it's fully on disk, so an interrupted install can't leave a
/// half-written binary in the path everything else invokes.
public actor StackInstaller {
    /// Apple signs the `container` installer with this team; a valid Developer ID from anyone
    /// else is not good enough (any paid account chains to the same root).
    static let appleContainerTeamID = "UPBK2H6LZM"

    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable { case downloading, verifying, unpacking, linking, done }
        public let component: EngineComponent
        public let phase: Phase
        /// 0…1 while downloading, nil when the phase has no measurable progress.
        public let fraction: Double?
    }

    private let layout: StackLayout
    private let fm = FileManager.default

    public init(layout: StackLayout = StackLayout()) {
        self.layout = layout
    }

    /// Installs one artifact and links it into `bin/`. Returns the executable's path.
    @discardableResult
    public func install(_ artifact: Artifact,
                        onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        let destination = layout.directory(for: artifact)
        let executable = layout.executable(for: artifact)
        if fm.isExecutableFile(atPath: executable.path) {
            try link(artifact)
            onProgress(Progress(component: artifact.component, phase: .done, fraction: 1))
            return executable
        }

        try fm.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
        let download = layout.downloadsDirectory
            .appending(path: "\(artifact.component.rawValue)-\(artifact.version)", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: download) }

        let digest = try await fetch(artifact, to: download, onProgress: onProgress)
        onProgress(Progress(component: artifact.component, phase: .verifying, fraction: nil))
        guard digest == artifact.sha256.lowercased() else {
            throw EngineError.digestMismatch(component: artifact.component,
                                             expected: artifact.sha256, actual: digest)
        }
        if case .applePackage = artifact.layout {
            try await verifyApplePackage(at: download)
        }

        onProgress(Progress(component: artifact.component, phase: .unpacking, fraction: nil))
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try await unpack(artifact, from: download, into: destination)
        } catch {
            try? fm.removeItem(at: destination)   // never leave a partial version behind
            throw error
        }

        onProgress(Progress(component: artifact.component, phase: .linking, fraction: nil))
        try link(artifact)
        onProgress(Progress(component: artifact.component, phase: .done, fraction: 1))
        return executable
    }

    /// Points `bin/<name>` at this version, replacing whatever was there. For the Compose plugin
    /// it also writes into `~/.docker/cli-plugins`, the only place `docker compose` looks.
    public func link(_ artifact: Artifact) throws {
        try fm.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        let source = layout.executable(for: artifact)
        try writeLauncher(at: layout.link(for: artifact.component), to: source)
        if artifact.component == .compose {
            try fm.createDirectory(at: layout.cliPluginsDirectory, withIntermediateDirectories: true)
            try writeLauncher(
                at: layout.cliPluginsDirectory.appending(path: "docker-compose", directoryHint: .notDirectory),
                to: source)
        }
    }

    /// The version an installed component reports, or nil if it isn't installed.
    public func installedVersion(of component: EngineComponent) async -> String? {
        let path = layout.link(for: component).path
        guard fm.isExecutableFile(atPath: path),
              let result = try? await ProcessRunner.run(path, component.versionArguments, timeout: .seconds(5)),
              result.succeeded else { return nil }
        return VersionText.semver(in: result.out)
    }

    // MARK: - Steps

    /// Downloads to `destination` and returns the file's hex SHA-256.
    ///
    /// `URLSession.download` does the transfer (it streams to disk and reports progress without
    /// the per-byte overhead of `bytes(from:)` — these artifacts are up to 100 MB), then the file
    /// is hashed in 1 MiB chunks so nothing large is ever resident in memory.
    private func fetch(_ artifact: Artifact, to destination: URL,
                       onProgress: @Sendable @escaping (Progress) -> Void) async throws -> String {
        guard let url = URL(string: artifact.url) else {
            throw EngineError.download("Bad URL for \(artifact.component.displayName).")
        }
        let component = artifact.component
        let reporter = DownloadProgress { fraction in
            onProgress(Progress(component: component, phase: .downloading, fraction: fraction))
        }
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: reporter)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineError.download("Couldn't download \(artifact.component.displayName).")
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temporary, to: destination)
        return try digest(of: destination)
    }

    private func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func verifyApplePackage(at url: URL) async throws {
        let result = try await ProcessRunner.run("/usr/sbin/pkgutil", ["--check-signature", url.path])
        guard result.succeeded, PackageSignature.isApple(result.out, teamID: Self.appleContainerTeamID) else {
            throw EngineError.untrustedPackage(result.out.isEmpty ? result.err : result.out)
        }
    }

    private func unpack(_ artifact: Artifact, from download: URL, into destination: URL) async throws {
        switch artifact.layout {
        case .applePackage:
            // `--expand-full` unpacks the payloads without running the installer, so no admin
            // rights and no system-wide side effects. Apple's own signed binaries are moved as
            // they are — never re-signed, so their entitlements survive.
            let work = destination.appending(path: ".expand", directoryHint: .isDirectory)
            try await ProcessRunner.check("/usr/sbin/pkgutil", ["--expand-full", download.path, work.path])
            guard let binary = findBinary(named: "container", under: work) else {
                throw EngineError.unpack("The package didn't contain a `container` binary.")
            }
            let installRoot = binary.deletingLastPathComponent().deletingLastPathComponent()
            for entry in (try? fm.contentsOfDirectory(at: installRoot, includingPropertiesForKeys: nil)) ?? [] {
                try fm.moveItem(at: entry, to: destination.appending(path: entry.lastPathComponent))
            }
            try? fm.removeItem(at: work)

        case let .tarball(binary, name):
            let work = destination.appending(path: ".extract", directoryHint: .isDirectory)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await ProcessRunner.check("/usr/bin/tar", ["-xzf", download.path, "-C", work.path])
            let extracted = work.appending(path: binary, directoryHint: .notDirectory)
            guard fm.fileExists(atPath: extracted.path) else {
                throw EngineError.unpack("The archive didn't contain \(binary).")
            }
            try fm.moveItem(at: extracted, to: destination.appending(path: name, directoryHint: .notDirectory))
            try? fm.removeItem(at: work)
            try makeExecutable(destination.appending(path: name, directoryHint: .notDirectory))

        case let .executable(name):
            let target = destination.appending(path: name, directoryHint: .notDirectory)
            try fm.moveItem(at: download, to: target)
            try makeExecutable(target)
        }
    }

    // MARK: - Filesystem helpers

    private func makeExecutable(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeLauncher(at path: URL, to target: URL) throws {
        try? fm.removeItem(at: path)
        try Data(LauncherScript.contents(for: target).utf8).write(to: path, options: .atomic)
        try makeExecutable(path)
    }

    private func findBinary(named name: String, under root: URL) -> URL? {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker
        where url.lastPathComponent == name
            && url.deletingLastPathComponent().lastPathComponent == "bin"
            && fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }
}

/// The stable `bin/` entries are tiny `exec` wrappers, not symlinks.
///
/// Apple's `container` locates `container-apiserver` next to its own `argv[0]`, so invoking it
/// through a symlink in a shared `bin/` makes `container system start` fail with a bare
/// "No such file or directory". `exec` replaces the process image with the real path, so the
/// helper lookup resolves — and the caller still only ever names a stable path.
public enum LauncherScript {
    public static func contents(for executable: URL) -> String {
        // Single-quoted and escaped: the install path contains a space ("Application Support"),
        // and a path is data, never shell to be re-parsed.
        let quoted = "'" + executable.path(percentEncoded: false).replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return """
        #!/bin/sh
        # Generated by Crane. Points at the installed version of this tool.
        exec \(quoted) "$@"

        """
    }

    /// The executable a launcher points at, or nil if the file isn't one of ours.
    public static func target(of script: String) -> String? {
        guard let line = script.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("exec ") }),
              let start = line.firstIndex(of: "'"),
              let end = line.lastIndex(of: "'"), start < end else { return nil }
        return String(line[line.index(after: start)..<end]).replacingOccurrences(of: #"'\''"#, with: "'")
    }
}

/// Pure parsing of `pkgutil --check-signature` output, so the trust rule is unit-tested.
public enum PackageSignature {
    /// True only when the package is notarized *and* signed by the given Apple team.
    ///
    /// Checking for "Apple Root CA" would be worthless: every Developer ID chains to it. The
    /// team identifier is the part that says *who* signed.
    public static func isApple(_ output: String, teamID: String) -> Bool {
        let notarized = output.lowercased().contains("notarization: trusted by the apple notary service")
        let signedByTeam = output.contains("Developer ID Installer: Apple Inc.")
            && output.contains("(\(teamID))")
        return notarized && signedByTeam
    }
}

/// Pure version-string handling shared by the installer and Engine status.
public enum VersionText {
    /// Pulls the first `1.2.3` out of a tool's `--version` chatter.
    public static func semver(in output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(output[range])
    }
}
