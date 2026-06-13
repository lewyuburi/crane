import Foundation

/// Errors surfaced by the `container` CLI integration.
enum ContainerCLIError: LocalizedError {
    case notInstalled
    case daemonNotRunning
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
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
actor ContainerCLI {
    static let shared = ContainerCLI()

    private let runtimes = RuntimeManager.shared

    /// The active runtime, or nil if none is installed/discovered.
    func activeRuntime() async -> Runtime? {
        await runtimes.activeRuntime()
    }

    var isInstalled: Bool {
        get async { await runtimes.activeRuntime() != nil }
    }

    /// Managed/bundled runtimes are fully isolated from a system install: their own
    /// install root (so the apiserver finds the right plugins/helpers), data root, log
    /// root, and launchd label (so the launch agents don't collide). Env var names
    /// verified against the real `container` 1.0.0 binary.
    static func environment(for runtime: Runtime) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let dataRoot = runtime.dataRoot else { return env }
        let installRoot = URL(fileURLWithPath: runtime.binaryPath)
            .deletingLastPathComponent().deletingLastPathComponent().path
        env["CONTAINER_INSTALL_ROOT"] = installRoot
        env["CONTAINER_APP_ROOT"] = dataRoot
        env["CONTAINER_LOG_ROOT"] = installRoot + "/logs"
        env["CONTAINER_DEBUG_LAUNCHD_LABEL"] = "dev.crane.container.\(runtime.version ?? "managed")"
        return env
    }

    static func configureEnvironment(for runtime: Runtime, on process: Process) {
        guard runtime.dataRoot != nil else { return }
        process.environment = environment(for: runtime)
    }

    /// Everything needed to attach a PTY terminal to a container via `container exec`.
    struct ExecInvocation {
        let executable: String
        let args: [String]
        /// Environment as "KEY=VALUE" entries (SwiftTerm's expected form).
        let environment: [String]
    }

    func execInvocation(id: String, command: [String]) async throws -> ExecInvocation {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        let env = Self.environment(for: runtime).map { "\($0.key)=\($0.value)" }
        return ExecInvocation(
            executable: runtime.binaryPath,
            args: ["exec", "--interactive", "--tty", id] + command,
            environment: env
        )
    }

    /// Builds a ready-to-run `container logs` process for streaming. The caller owns
    /// the process lifecycle (run/terminate) — see `LogStream`.
    func logProcess(id: String, follow: Bool, tail: Int?) async throws -> Process {
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

    func listContainers() async throws -> [Container] {
        let data = try await run(["ls", "--all", "--format", "json"])
        return try ContainerDecoding.decodeContainers(from: data)
    }

    func runContainer(_ spec: RunSpec) async throws {
        try await run(["run"] + Self.withDefaultDNS(spec.arguments()))
    }

    // MARK: - Compose orchestration helpers

    func runDetached(arguments: [String]) async throws {
        try await run(["run"] + Self.withDefaultDNS(arguments))
    }

    /// Apple `container`'s per-network gateway resolver (192.168.65.1) intermittently fails
    /// IPv4 (A-record) forwarding — and doesn't resolve sibling container names either — so
    /// containers can't reach the internet by hostname. We default `--dns` to the host's own
    /// resolvers (which work) unless the caller already set one, mirroring how OrbStack runs a
    /// reliable resolver for its containers.
    static func withDefaultDNS(_ arguments: [String]) -> [String] {
        guard !arguments.contains("--dns") else { return arguments }
        return hostDNSServers().flatMap { ["--dns", $0] } + arguments
    }

    /// Host DNS resolvers from /etc/resolv.conf, minus loopback/link-local ones the guest VM
    /// can't reach. Falls back to public resolvers if none are usable.
    static func hostDNSServers() -> [String] {
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

    func buildImage(_ build: ComposeBuild, tag: String) async throws {
        var args = ["build", "--tag", tag, "--progress", "plain"]
        if let dockerfile = build.dockerfile { args += ["--file", dockerfile] }
        for arg in build.args { args += ["--build-arg", arg] }
        args.append(build.context)
        try await run(args)
    }

    func createNetworkIfNeeded(_ name: String) async {
        let existing = (try? await listNetworks())?.map(\.name) ?? []
        if !existing.contains(name) { _ = try? await run(["network", "create", name]) }
    }

    func createVolumeIfNeeded(_ name: String) async {
        let existing = (try? await listVolumes())?.map(\.name) ?? []
        if !existing.contains(name) { _ = try? await run(["volume", "create", name]) }
    }

    func start(id: String) async throws { try await run(["start", id]) }
    func stop(id: String) async throws { try await run(["stop", id]) }
    func kill(id: String) async throws { try await run(["kill", id]) }
    func delete(id: String) async throws { try await run(["delete", id]) }

    /// One stats sample for a container, or nil if unavailable.
    func stats(id: String) async -> ContainerStats? {
        guard let data = try? await run(["stats", "--no-stream", "--format", "json", id]) else {
            return nil
        }
        return StatsDecoding.decode(from: data).first
    }

    // MARK: - Machines

    func listMachines() async throws -> [Machine] {
        let data = try await run(["machine", "list", "--format", "json"])
        return MachineDecoding.decode(from: data)
    }

    func machineCreate(image: String, name: String) async throws {
        try await run(["machine", "create", "--name", name, image])
    }

    /// Boots a stopped machine by running a no-op (there is no `machine start`).
    func machineBoot(name: String) async throws {
        try await run(["machine", "run", "--name", name, "--detach", "true"])
    }

    func machineStop(name: String) async throws { try await run(["machine", "stop", name]) }
    func machineDelete(name: String) async throws { try await run(["machine", "delete", name]) }
    func machineSetDefault(name: String) async throws { try await run(["machine", "set-default", name]) }

    /// A PTY invocation for an interactive shell in a machine (`machine run -it -n`).
    func machineShellInvocation(name: String) async throws -> ExecInvocation {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        let env = Self.environment(for: runtime).map { "\($0.key)=\($0.value)" }
        return ExecInvocation(
            executable: runtime.binaryPath,
            args: ["machine", "run", "--interactive", "--tty", "--name", name],
            environment: env
        )
    }

    func logs(id: String) async throws -> String {
        let data = try await run(["logs", id])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Images

    func listImages() async throws -> [ContainerImage] {
        let data = try await run(["image", "ls", "--format", "json"])
        return try ContainerDecoding.decodeImages(from: data)
    }

    func deleteImages(references: [String]) async throws {
        guard !references.isEmpty else { return }
        try await run(["image", "delete"] + references)
    }

    /// A ready-to-run `image pull --progress plain` process for streaming progress.
    func pullProcess(reference: String) async throws -> Process {
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

    func listVolumes() async throws -> [Volume] {
        let data = try await run(["volume", "ls", "--format", "json"])
        return VolumeNetworkDecoding.decodeVolumes(from: data)
    }

    func createVolume(name: String, size: String?) async throws {
        var args = ["volume", "create"]
        if let size, !size.isEmpty { args += ["-s", size] }
        args.append(name)
        try await run(args)
    }

    func deleteVolume(name: String) async throws { try await run(["volume", "delete", name]) }
    func pruneVolumes() async throws { try await run(["volume", "prune"]) }

    // MARK: - Networks

    func listNetworks() async throws -> [Network] {
        let data = try await run(["network", "ls", "--format", "json"])
        return VolumeNetworkDecoding.decodeNetworks(from: data)
    }

    func createNetwork(name: String, subnet: String?) async throws {
        var args = ["network", "create"]
        if let subnet, !subnet.isEmpty { args += ["--subnet", subnet] }
        args.append(name)
        try await run(args)
    }

    func deleteNetwork(name: String) async throws { try await run(["network", "delete", name]) }

    // MARK: - Disk usage

    func diskUsage() async -> DiskUsage? {
        guard let data = try? await run(["system", "df", "--format", "json"]) else { return nil }
        return VolumeNetworkDecoding.decodeDiskUsage(from: data)
    }

    func pruneImages() async throws { try await run(["image", "prune"]) }
    func pruneContainers() async throws { try await run(["prune"]) }

    // MARK: - System

    /// Starts the apiserver. For managed/bundled runtimes we pass the roots as explicit
    /// flags (the launch agent does NOT inherit our env, so `--app-root` is the only way
    /// to actually isolate its data) and auto-install the default kernel on first run.
    func systemStart() async throws {
        guard let runtime = await runtimes.activeRuntime() else {
            throw ContainerCLIError.notInstalled
        }
        var args = ["system", "start", "--enable-kernel-install"]
        if let dataRoot = runtime.dataRoot {
            let installRoot = URL(fileURLWithPath: runtime.binaryPath)
                .deletingLastPathComponent().deletingLastPathComponent().path
            args += [
                "--app-root", dataRoot,
                "--install-root", installRoot,
                "--log-root", installRoot + "/logs",
            ]
        }
        try await run(args)
    }

    func systemStop() async throws { try await run(["system", "stop"]) }

    /// Whether the apiserver for the active runtime is up. Never throws.
    func isSystemRunning() async -> Bool {
        guard (try? await run(["system", "status"])) != nil else { return false }
        return true
    }
}
