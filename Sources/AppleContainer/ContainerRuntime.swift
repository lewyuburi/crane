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

    /// Whether launchd currently has a PID for the apiserver.
    public func isSystemRunning() async -> Bool {
        let domain = "gui/\(getuid())"
        guard let result = try? await ProcessRunner.run(
            "/bin/launchctl", ["print", "\(domain)/\(Self.apiserverJob)"],
            timeout: .seconds(3)
        ), result.succeeded else { return false }
        return result.out.range(of: #"(?m)^\s*pid\s*=\s*\d+"#, options: .regularExpression) != nil
    }

    /// Starts the apiserver, installing the default kernel on first run.
    ///
    /// Idempotent by design: when the service is already up this is a no-op, which is what lets
    /// it double as the login-time launch agent.
    public func startSystem() async throws {
        if await isSystemRunning() { return }
        try await ProcessRunner.check(executable, ["system", "start", "--enable-kernel-install"],
                                     timeout: .seconds(60))
    }

    public func stopSystem() async throws {
        try await ProcessRunner.check(executable, ["system", "stop"], timeout: .seconds(30))
    }
}
