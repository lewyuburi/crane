import Foundation

/// Errors surfaced by the `container` CLI integration.
public enum ContainerCLIError: LocalizedError, Sendable {
    case notInstalled
    case daemonNotRunning
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The `container` CLI was not found. Install Apple's container tool from https://github.com/apple/container."
        case .daemonNotRunning:
            return "The container system service isn't running. Start it with `container system start`."
        case let .commandFailed(command, code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` failed (exit \(code)).\(detail.isEmpty ? "" : "\n\(detail)")"
        }
    }
}

/// Thin async wrapper over the public `container` CLI.
///
/// We deliberately shell out to the stable CLI (with `--format json`) rather than
/// talking to the private XPC api-server, which is versioned and changes between
/// releases. This keeps Crane resilient across `container` upgrades.
public actor ContainerCLI {
    public static let shared = ContainerCLI()

    private let runtimes = RuntimeManager.shared

    /// The active runtime, or nil if none is installed/discovered.
    public func activeRuntime() async -> Runtime? {
        await runtimes.activeRuntime()
    }

    public var isInstalled: Bool {
        get async { await runtimes.activeRuntime() != nil }
    }

    /// Managed/bundled runtimes are fully isolated from a system install: their own
    /// install root (so the apiserver finds the right plugins/helpers), data root, log
    /// root, and launchd label (so the launch agents don't collide). Env var names
    /// verified against the real `container` 1.0.0 binary.
    public static func environment(for runtime: Runtime) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let dataRoot = runtime.dataRoot else { return env }
        let installRoot = runtime.installRoot
        env["CONTAINER_INSTALL_ROOT"] = installRoot
        env["CONTAINER_APP_ROOT"] = dataRoot
        env["CONTAINER_LOG_ROOT"] = installRoot + "/logs"
        env["CONTAINER_DEBUG_LAUNCHD_LABEL"] = "dev.crane.container.\(runtime.version ?? "managed")"
        return env
    }

    public static func configureEnvironment(for runtime: Runtime, on process: Process) {
        guard runtime.dataRoot != nil else { return }
        process.environment = environment(for: runtime)
    }

    /// Everything needed to attach a PTY terminal to a container via `container exec`.
    public struct ExecInvocation: Sendable {
        public let executable: String
        public let args: [String]
        /// Environment as "KEY=VALUE" entries (SwiftTerm's expected form).
        public let environment: [String]
    }

    /// Build a `container exec` invocation. `interactive`/`tty` default to true (the GUI terminal
    /// always wants an interactive PTY); the CLI passes the user's actual `-i`/`-t` so a
    /// non-interactive `docker exec web cat file` doesn't get a spurious TTY.
    public func execInvocation(id: String, command: [String],
                               interactive: Bool = true, tty: Bool = true) async throws -> ExecInvocation {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        let env = Self.environment(for: runtime).map { "\($0.key)=\($0.value)" }
        var flags: [String] = []
        if interactive { flags.append("--interactive") }
        if tty { flags.append("--tty") }
        return ExecInvocation(
            executable: runtime.binaryPath,
            args: ["exec"] + flags + [id] + command,
            environment: env
        )
    }

    /// Builds a ready-to-run `container logs` process for streaming. The caller owns
    /// the process lifecycle (run/terminate) — see `LogStream`.
    public func logProcess(id: String, follow: Bool, tail: Int?) async throws -> Process {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        var args = ["logs"]
        if follow { args.append("--follow") }
        if let tail { args += ["-n", String(tail)] }
        args.append(id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.binaryPath)
        process.arguments = args
        Self.configureEnvironment(for: runtime, on: process)
        return process
    }

    /// A ready-to-run `container <arguments>` process that inherits the caller's stdio. Used by the
    /// docker-compat shim to pass commands we don't wrap (build, pull, inspect…) straight through.
    public func passthroughProcess(arguments: [String]) async throws -> Process {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.binaryPath)
        process.arguments = arguments
        Self.configureEnvironment(for: runtime, on: process)
        return process
    }

    // MARK: - Process execution

    @discardableResult
    private func run(_ arguments: [String]) async throws -> Data {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }

        let result = try await ProcessRunner.run(
            executable: runtime.binaryPath,
            arguments: arguments,
            environment: Self.environment(for: runtime)
        )

        guard result.status == 0 else {
            let stderrString = String(decoding: result.stderr, as: UTF8.self)
            if stderrString.localizedCaseInsensitiveContains("not running")
                || stderrString.localizedCaseInsensitiveContains("connection") {
                throw ContainerCLIError.daemonNotRunning
            }
            throw ContainerCLIError.commandFailed(
                command: "container " + arguments.joined(separator: " "),
                exitCode: result.status,
                stderr: stderrString
            )
        }
        return result.stdout
    }

    // MARK: - Containers

    public func listContainers() async throws -> [Container] {
        let data = try await run(["ls", "--all", "--format", "json"])
        return try ContainerDecoding.decodeContainers(from: data)
    }

    public func runContainer(_ spec: RunSpec) async throws {
        try await run(["run"] + Self.withDefaultDNS(spec.arguments()))
    }

    // MARK: - Compose orchestration helpers

    public func runDetached(arguments: [String]) async throws {
        try await run(["run"] + Self.withDefaultDNS(arguments))
    }

    /// Create a container without starting it (used to recreate a *stopped* container so it
    /// keeps its stopped state).
    public func createStopped(arguments: [String]) async throws {
        try await run(["create"] + Self.withDefaultDNS(arguments))
    }

    /// Apple `container`'s per-network gateway resolver (192.168.65.1) intermittently fails
    /// IPv4 (A-record) forwarding — and doesn't resolve sibling container names either — so
    /// containers can't reach the internet by hostname. We default `--dns` to the host's own
    /// resolvers (which work) unless the caller already set one, mirroring how OrbStack runs a
    /// reliable resolver for its containers.
    public static func withDefaultDNS(_ arguments: [String]) -> [String] {
        guard !arguments.contains("--dns") else { return arguments }
        return hostDNSServers().flatMap { ["--dns", $0] } + arguments
    }

    /// Host DNS resolvers from /etc/resolv.conf, minus loopback/link-local ones the guest VM
    /// can't reach. Falls back to public resolvers if none are usable.
    public static func hostDNSServers() -> [String] {
        let parsed = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard f.count >= 2, f[0] == "nameserver" else { return nil }
                return String(f[1])
            }
            .filter { !$0.hasPrefix("127.") && $0 != "::1" && !$0.lowercased().hasPrefix("fe80") } ?? []
        return parsed.isEmpty ? ["1.1.1.1", "8.8.8.8"] : parsed
    }

    /// The internal DNS domain configured for container-to-container name resolution, or nil.
    /// Multi-service stacks need this (`[dns].domain` in config.toml + a matching `system dns
    /// create <domain>`); see the experimental stack support in AppModel.
    public func configuredDNSDomain() -> String? {
        let path = NSHomeDirectory() + "/.config/container/config.toml"
        guard let toml = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Self.dnsDomain(inTOML: toml)
    }

    /// Extracts `domain = "x"` from the `[dns]` section of a config.toml string (pure/testable).
    public static func dnsDomain(inTOML toml: String) -> String? {
        var inDNS = false
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inDNS = (line == "[dns]"); continue }
            guard inDNS, line.hasPrefix("domain"), let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                // Quoted: content up to the matching closing quote (ignores any trailing comment).
                if let close = value.dropFirst().firstIndex(of: quote) {
                    return String(value[value.index(after: value.startIndex)..<close])
                }
            }
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }  // strip inline comment
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Run a one-shot command in a running container and return its stdout.
    @discardableResult
    public func exec(id: String, command: [String]) async throws -> Data {
        try await run(["exec", id] + command)
    }

    public func buildImage(_ build: ComposeBuild, tag: String) async throws {
        var args = ["build", "--tag", tag, "--progress", "plain"]
        if let dockerfile = build.dockerfile { args += ["--file", dockerfile] }
        for arg in build.args { args += ["--build-arg", arg] }
        args.append(build.context)
        try await run(args)
    }

    public func createNetworkIfNeeded(_ name: String) async {
        let existing = (try? await listNetworks())?.map(\.name) ?? []
        if !existing.contains(name) { _ = try? await run(["network", "create", name]) }
    }

    public func createVolumeIfNeeded(_ name: String) async {
        let existing = (try? await listVolumes())?.map(\.name) ?? []
        if !existing.contains(name) { _ = try? await run(["volume", "create", name]) }
    }

    public func start(id: String) async throws { try await run(["start", id]) }
    public func stop(id: String) async throws { try await run(["stop", id]) }
    public func kill(id: String) async throws { try await run(["kill", id]) }
    public func delete(id: String, force: Bool = false) async throws {
        try await run(["delete"] + (force ? ["--force"] : []) + [id])
    }

    /// One stats sample for a container, or nil if unavailable.
    public func stats(id: String) async -> ContainerStats? {
        guard let data = try? await run(["stats", "--no-stream", "--format", "json", id]) else {
            return nil
        }
        return StatsDecoding.decode(from: data).first
    }

    // MARK: - Images

    public func listImages() async throws -> [ContainerImage] {
        let data = try await run(["image", "ls", "--format", "json"])
        return try ContainerDecoding.decodeImages(from: data)
    }

    public func deleteImages(references: [String]) async throws {
        guard !references.isEmpty else { return }
        try await run(["image", "delete"] + references)
    }

    /// A ready-to-run `image pull --progress plain` process for streaming progress.
    public func pullProcess(reference: String) async throws -> Process {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.binaryPath)
        process.arguments = ["image", "pull", "--progress", "plain", reference]
        Self.configureEnvironment(for: runtime, on: process)
        return process
    }

    // MARK: - Volumes

    public func listVolumes() async throws -> [Volume] {
        let data = try await run(["volume", "ls", "--format", "json"])
        return VolumeNetworkDecoding.decodeVolumes(from: data)
    }

    public func createVolume(name: String, size: String?) async throws {
        var args = ["volume", "create"]
        if let size, !size.isEmpty { args += ["-s", size] }
        args.append(name)
        try await run(args)
    }

    public func deleteVolume(name: String) async throws { try await run(["volume", "delete", name]) }
    public func pruneVolumes() async throws { try await run(["volume", "prune"]) }

    // MARK: - Networks

    public func listNetworks() async throws -> [Network] {
        let data = try await run(["network", "ls", "--format", "json"])
        return VolumeNetworkDecoding.decodeNetworks(from: data)
    }

    public func createNetwork(name: String, subnet: String?) async throws {
        var args = ["network", "create"]
        if let subnet, !subnet.isEmpty { args += ["--subnet", subnet] }
        args.append(name)
        try await run(args)
    }

    public func deleteNetwork(name: String) async throws { try await run(["network", "delete", name]) }

    // MARK: - Disk usage

    public func diskUsage() async -> DiskUsage? {
        guard let data = try? await run(["system", "df", "--format", "json"]) else { return nil }
        return VolumeNetworkDecoding.decodeDiskUsage(from: data)
    }

    public func pruneImages() async throws { try await run(["image", "prune"]) }
    public func pruneContainers() async throws { try await run(["prune"]) }

    // MARK: - System

    /// Starts the apiserver. For managed/bundled runtimes we pass the roots as explicit
    /// flags (the launch agent does NOT inherit our env, so `--app-root` is the only way
    /// to actually isolate its data) and auto-install the default kernel on first run.
    public func systemStart() async throws {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        var args = ["system", "start", "--enable-kernel-install"]
        if let dataRoot = runtime.dataRoot {
            let installRoot = runtime.installRoot
            args += [
                "--app-root", dataRoot,
                "--install-root", installRoot,
                "--log-root", installRoot + "/logs",
            ]
        }
        try await run(args)
    }

    public func systemStop() async throws { try await run(["system", "stop"]) }

    /// Whether the apiserver for the active runtime is up. Never throws.
    public func isSystemRunning() async -> Bool {
        guard (try? await run(["system", "status"])) != nil else { return false }
        return true
    }
}
