import Foundation

/// Where a `container` runtime came from.
enum RuntimeSource: String, Hashable {
    /// Installed system-wide by Apple's `.pkg` (under /usr/local or Homebrew).
    case system
    /// Downloaded and managed by Crane under Application Support.
    case managed
    /// Shipped inside Crane.app/Contents/Helpers (OrbStack-style bundle).
    case bundled
}

/// A discovered `container` runtime: a binary plus its provenance and version.
struct Runtime: Identifiable, Hashable {
    var id: String { binaryPath }
    let binaryPath: String
    let source: RuntimeSource
    var version: String?

    /// Isolated data root for managed/bundled runtimes so they never collide
    /// with a system install's state. `nil` means "use the runtime's default".
    var dataRoot: String?

    var displayName: String {
        let v = version ?? "unknown"
        return "\(source.rawValue) · \(v)"
    }
}

/// Resolves which `container` binary Crane drives and lets the user manage versions.
///
/// This is the abstraction layer that makes the "bundle vs. download vs. system"
/// decision a runtime detail rather than something baked into `ContainerCLI`.
/// Strategy A (managed downloads) and B (bundled) both plug in here.
actor RuntimeManager {
    static let shared = RuntimeManager()

    private let fm = FileManager.default
    private let activeKey = "crane.activeRuntimePath"

    /// Root for Crane-managed runtimes: ~/Library/Application Support/Crane/runtimes
    var managedRoot: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crane/runtimes", isDirectory: true)
    }

    /// Helpers directory inside the app bundle (Strategy B), if present.
    private var bundledRoot: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    // MARK: - Discovery

    /// All runtimes Crane can find, in preference order: managed, bundled, system.
    func discover() async -> [Runtime] {
        var found: [Runtime] = []
        found.append(contentsOf: discoverManaged())
        found.append(contentsOf: discoverBundled())
        found.append(contentsOf: discoverSystem())

        // Resolve versions concurrently.
        return await withTaskGroup(of: Runtime.self) { group in
            for rt in found {
                group.addTask { await Self.resolvingVersion(rt) }
            }
            var result: [Runtime] = []
            for await rt in group { result.append(rt) }
            return result.sorted { $0.source.rawValue < $1.source.rawValue }
        }
    }

    private func discoverManaged() -> [Runtime] {
        let versionsDir = managedRoot
        guard let entries = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { dir in
            let bin = dir.appendingPathComponent("bin/container").path
            guard fm.isExecutableFile(atPath: bin) else { return nil }
            return Runtime(
                binaryPath: bin,
                source: .managed,
                version: nil,
                dataRoot: dir.appendingPathComponent("data").path
            )
        }
    }

    private func discoverBundled() -> [Runtime] {
        guard let root = bundledRoot else { return [] }
        let bin = root.appendingPathComponent("container").path
        guard fm.isExecutableFile(atPath: bin) else { return [] }
        let data = managedRoot.deletingLastPathComponent()
            .appendingPathComponent("bundled-data").path
        return [Runtime(binaryPath: bin, source: .bundled, version: nil, dataRoot: data)]
    }

    private func discoverSystem() -> [Runtime] {
        let candidates = [
            "/usr/local/bin/container",
            "/opt/homebrew/bin/container",
            "/usr/bin/container",
        ]
        return candidates
            .filter { fm.isExecutableFile(atPath: $0) }
            .map { Runtime(binaryPath: $0, source: .system, version: nil, dataRoot: nil) }
    }

    // MARK: - Active selection

    /// Cached active runtime — resolving it spawns `--version` probes, so we must NOT
    /// re-discover on every CLI command (that was the main source of UI lag).
    private var cachedActive: Runtime?

    /// The runtime Crane currently drives: the user's pick if still present,
    /// otherwise the first discovered (managed > bundled > system). Cached.
    func activeRuntime() async -> Runtime? {
        if let cachedActive { return cachedActive }
        let resolved = await resolveActiveRuntime()
        cachedActive = resolved
        return resolved
    }

    private func resolveActiveRuntime() async -> Runtime? {
        let all = await discover()
        if let saved = UserDefaults.standard.string(forKey: activeKey),
           let match = all.first(where: { $0.binaryPath == saved }) {
            return match
        }
        return all.first
    }

    /// Drops the cache so the next `activeRuntime()` re-resolves (e.g. after install/remove).
    func invalidate() { cachedActive = nil }

    func setActive(_ runtime: Runtime) {
        UserDefaults.standard.set(runtime.binaryPath, forKey: activeKey)
        cachedActive = runtime
    }

    // MARK: - Version probe

    private static func resolvingVersion(_ runtime: Runtime) async -> Runtime {
        var rt = runtime
        rt.version = await probeVersion(at: runtime.binaryPath)
        return rt
    }

    private static func probeVersion(at path: String) async -> String? {
        guard let result = try? await ProcessRunner.run(executable: path, arguments: ["--version"]),
              result.status == 0 else { return nil }
        let out = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize "container CLI version 1.0.0 (build: …)" → "1.0.0".
        if let range = out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
            return String(out[range])
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Version management (Strategy A)

    /// Available `container` releases from GitHub, newest first.
    func availableReleases() async throws -> [RemoteRelease] {
        let url = URL(string: "https://api.github.com/repos/apple/container/releases")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError.download("GitHub releases request failed")
        }
        let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return raw.compactMap { obj in
            guard let tag = obj["tag_name"] as? String else { return nil }
            let prerelease = (obj["prerelease"] as? Bool) ?? false
            return RemoteRelease(version: tag, isPrerelease: prerelease)
        }
    }

    /// Downloads Apple's signed `.pkg` for `version`, extracts it WITHOUT installing
    /// system-wide (no admin), and lays it out under managedRoot/<version>/.
    ///
    /// We run Apple's already-signed binary as-is — never re-signing — so the
    /// `com.apple.security.virtualization` entitlement rides along on Apple's signature.
    @discardableResult
    func install(version: String) async throws -> Runtime {
        let asset = "container-\(version)-installer-signed.pkg"
        guard let url = URL(string:
            "https://github.com/apple/container/releases/download/\(version)/\(asset)") else {
            throw RuntimeError.download("Bad release URL for \(version)")
        }

        // 1. Download the signed pkg to a temp file.
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError.download("Download failed for \(asset)")
        }

        // 2. Expand the pkg (xar + cpio payloads) without running the installer.
        let work = managedRoot.appendingPathComponent(".work-\(version)", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        try await runTool("/usr/sbin/pkgutil", ["--expand-full", downloaded.path, work.path])

        // 3. Find the install root by locating `bin/container` in the payload tree.
        guard let containerBin = findContainerBinary(under: work) else {
            try? fm.removeItem(at: work)
            throw RuntimeError.download("Couldn't find `container` binary in \(asset)")
        }
        let installRoot = containerBin.deletingLastPathComponent().deletingLastPathComponent()

        // 4. Move the layout into managedRoot/<version>/ (bin/, libexec/, ...).
        let versionDir = managedRoot.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: versionDir)
        try fm.moveItem(at: installRoot, to: versionDir)
        try? fm.removeItem(at: work)

        return Runtime(
            binaryPath: versionDir.appendingPathComponent("bin/container").path,
            source: .managed,
            version: version,
            dataRoot: versionDir.appendingPathComponent("data").path
        )
    }

    /// Recursively locate a `.../bin/container` executable in the expanded payload.
    private func findContainerBinary(under root: URL) -> URL? {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "container",
               url.deletingLastPathComponent().lastPathComponent == "bin",
               fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func runTool(_ path: String, _ args: [String]) async throws {
        let result = try await ProcessRunner.run(executable: path, arguments: args)
        guard result.status == 0 else {
            throw RuntimeError.download("\(path) failed: \(String(decoding: result.stderr, as: UTF8.self))")
        }
    }

    func remove(_ runtime: Runtime) throws {
        guard runtime.source == .managed else {
            throw RuntimeError.notImplemented("Only managed runtimes can be removed")
        }
        // versionDir is .../<version>/, binaryPath is .../<version>/bin/container
        let versionDir = URL(fileURLWithPath: runtime.binaryPath)
            .deletingLastPathComponent().deletingLastPathComponent()
        try fm.removeItem(at: versionDir)
        if cachedActive?.binaryPath == runtime.binaryPath { cachedActive = nil }
    }
}

/// A `container` release available for download from GitHub.
struct RemoteRelease: Identifiable, Hashable {
    var id: String { version }
    let version: String
    let isPrerelease: Bool
}

enum RuntimeError: LocalizedError {
    case notImplemented(String)
    case download(String)
    var errorDescription: String? {
        switch self {
        case let .notImplemented(what): return "Not implemented yet: \(what)"
        case let .download(detail): return detail
        }
    }
}
