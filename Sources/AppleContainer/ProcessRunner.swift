import Foundation

/// Runs a short-lived tool and collects its output.
///
/// Crane 2.0 keeps process spawning out of the UI's hot path — this exists for the handful of
/// things only the native binaries can do (installing the stack, `container machine`, kernel
/// setup), not for reading state.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data

        public var out: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        public var err: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        public var succeeded: Bool { status == 0 }
    }

    public enum Failure: Error, LocalizedError {
        case notExecutable(String)
        case failed(command: String, status: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case let .notExecutable(path):
                return "\(path) is missing or not executable."
            case let .failed(command, status, stderr):
                return stderr.isEmpty ? "`\(command)` failed (exit \(status))." : "`\(command)`: \(stderr)"
            }
        }
    }

    /// Runs `executable` and waits for it. Never blocks the calling thread: the process is
    /// launched on a detached task and awaited through its termination handler.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String] = [],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notExecutable(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withCheckedThrowingContinuation { continuation in
            // Read both pipes concurrently before waiting: a tool that fills the 64 KiB pipe
            // buffer would otherwise deadlock against our wait.
            let outData = UnsafeSendableBox(Data()), errData = UnsafeSendableBox(Data())
            let group = DispatchGroup()
            for (pipe, box) in [(out, outData), (err, errData)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
            }
            process.terminationHandler = { proc in
                group.wait()
                continuation.resume(returning: Result(status: proc.terminationStatus,
                                                      stdout: outData.value, stderr: errData.value))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs and throws unless the tool exited cleanly.
    @discardableResult
    public static func check(_ executable: String, _ arguments: [String] = [],
                             environment: [String: String]? = nil,
                             currentDirectory: URL? = nil) async throws -> Result {
        let result = try await run(executable, arguments, environment: environment,
                                   currentDirectory: currentDirectory)
        guard result.succeeded else {
            throw Failure.failed(command: ([executable] + arguments).joined(separator: " "),
                                 status: result.status, stderr: result.err)
        }
        return result
    }
}

/// Minimal box so the pipe readers can hand their bytes back to the continuation. The two
/// writers touch distinct boxes and are joined by the DispatchGroup before either is read.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
