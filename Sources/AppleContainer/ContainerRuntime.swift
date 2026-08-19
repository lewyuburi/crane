import Foundation

/// The native `container` binary — used only for what the Docker API can't express.
///
/// Crane reads state through the Docker socket, never through this. What lives here is the
/// runtime's own surface: bringing the apiserver up, kernels, and the PTY behind `container exec`.
public struct ContainerRuntime: Sendable {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    public func version() async -> String? {
        guard let result = try? await ProcessRunner.run(executable, ["--version"]), result.succeeded else {
            return nil
        }
        return result.out
    }

    /// Whether the apiserver is up. `container system status` exits non-zero when it isn't.
    public func isSystemRunning() async -> Bool {
        guard let result = try? await ProcessRunner.run(executable, ["system", "status"]) else { return false }
        return result.succeeded
    }

    /// Starts the apiserver, installing the default kernel on first run.
    ///
    /// Idempotent by design: when the service is already up this is a no-op, which is what lets
    /// it double as the login-time launch agent.
    public func startSystem() async throws {
        if await isSystemRunning() { return }
        try await ProcessRunner.check(executable, ["system", "start", "--enable-kernel-install"])
    }

    public func stopSystem() async throws {
        try await ProcessRunner.check(executable, ["system", "stop"])
    }
}
