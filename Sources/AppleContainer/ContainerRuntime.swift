import Foundation

/// The native `container` binary — used only for what the Docker API can't express.
///
/// Crane reads state through the Docker socket, never through this. What lives here is the
/// runtime's own surface: bringing the apiserver up, kernels, and the PTY behind `container exec`.
public struct ContainerRuntime: Sendable {
    /// Apple's user-session job. `container system status` talks to this over XPC and can hang
    /// forever if the Mach service is wedged, so Crane never waits on that CLI for a probe.
    public static let apiserverJob = "com.apple.container.apiserver"

    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    public func version() async -> String? {
        guard let result = try? await ProcessRunner.run(executable, ["--version"], timeout: .seconds(5)),
              result.succeeded else {
            return nil
        }
        return result.out
    }

    /// Whether the apiserver is up enough for XPC clients. A PID with `active = 0` is a wedged
    /// Mach service: `container system status` and socktainer hang instead of binding the socket.
    public func isSystemRunning() async -> Bool {
        let domain = "gui/\(getuid())"
        guard let result = try? await ProcessRunner.run(
            "/bin/launchctl", ["print", "\(domain)/\(Self.apiserverJob)"],
            timeout: .seconds(3)
        ), result.succeeded else { return false }
        return result.out.range(of: #"(?m)^\s*pid\s*=\s*\d+"#, options: .regularExpression) != nil
            && result.out.range(of: #"(?m)^\s*active\s*=\s*[1-9]"#, options: .regularExpression) != nil
    }

    /// Whether launchd currently has a PID for the apiserver, even if XPC hasn't checked in.
    private func hasPID() async -> Bool {
        let domain = "gui/\(getuid())"
        guard let result = try? await ProcessRunner.run(
            "/bin/launchctl", ["print", "\(domain)/\(Self.apiserverJob)"],
            timeout: .seconds(3)
        ), result.succeeded else { return false }
        return result.out.range(of: #"(?m)^\s*pid\s*=\s*\d+"#, options: .regularExpression) != nil
    }

    /// Starts the apiserver, installing the default kernel on first run.
    ///
    /// Idempotent when the Mach service is actually serving. A wedged PID (process up, XPC
    /// dead) is unloaded first so `system start` can register a fresh job instead of hanging.
    public func startSystem() async throws {
        if await isSystemRunning() { return }
        if await hasPID() {
            _ = try? await ProcessRunner.run(
                "/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.apiserverJob)"],
                timeout: .seconds(8))
        }
        try await ProcessRunner.check(executable, ["system", "start", "--enable-kernel-install"],
                                     timeout: .seconds(60))
    }

    public func stopSystem() async throws {
        try await ProcessRunner.check(executable, ["system", "stop"], timeout: .seconds(30))
    }
}
