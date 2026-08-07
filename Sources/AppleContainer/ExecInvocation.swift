import Foundation

/// Everything needed to attach a terminal to a running container.
public struct ExecInvocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// `KEY=VALUE` entries, the form terminal emulators expect.
    public let environment: [String]

    public init(executable: String, arguments: [String], environment: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public extension ContainerRuntime {
    /// Builds a `container exec -it` invocation.
    ///
    /// The shell goes through the native CLI rather than the Docker API on purpose: it gives a
    /// real PTY, so job control, resizing and full-screen programs behave as they would in
    /// Terminal. An HTTP-hijacked exec is a worse terminal for no benefit here.
    func shellInvocation(containerID: String, shell: [String] = ["/bin/sh"]) -> ExecInvocation {
        ExecInvocation(
            executable: executable,
            arguments: ["exec", "--interactive", "--tty", containerID] + shell,
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        )
    }

    /// Runs a command in a container and returns its combined output. Used for the small
    /// questions a terminal shouldn't have to answer, like listing a directory.
    func output(containerID: String, command: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable, ["exec", containerID] + command)
        return result.succeeded ? result.out : result.err
    }
}
