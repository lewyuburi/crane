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
        case timedOut(command: String, seconds: Double)

        public var errorDescription: String? {
            switch self {
            case let .notExecutable(path):
                return "\(path) is missing or not executable."
            case let .failed(command, status, stderr):
                return stderr.isEmpty ? "`\(command)` failed (exit \(status))." : "`\(command)`: \(stderr)"
            case let .timedOut(command, seconds):
                return "`\(command)` did not finish in \(Int(seconds.rounded(.up)))s."
            }
        }
    }

    /// Runs `executable` and waits for it. Never blocks the calling thread: the process is
    /// launched on a detached task and awaited through its termination handler.
    ///
    /// Pass `timeout` for probes that can hang (XPC to a wedged apiserver). Installers that
    /// unpack archives omit it and wait until the child exits.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String] = [],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           timeout: Duration? = nil) async throws -> Result {
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
        let command = ([executable] + arguments).joined(separator: " ")

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            // Read both pipes concurrently before waiting: a tool that fills the 64 KiB pipe
            // buffer would otherwise deadlock against our wait.
            let outData = UnsafeSendableBox(Data()), errData = UnsafeSendableBox(Data())
            let expired = Flag()
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
                if expired.value {
                    once.resume(throwing: Failure.timedOut(command: command,
                                                           seconds: timeout.map(Self.seconds(in:)) ?? 0))
                } else {
                    once.resume(returning: Result(status: proc.terminationStatus,
                                                  stdout: outData.value, stderr: errData.value))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                once.resume(throwing: error)
                return
            }
            if let timeout {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds(in: timeout)) {
                    expired.value = true
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                        guard process.isRunning else { return }
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    /// Runs and throws unless the tool exited cleanly.
    @discardableResult
    public static func check(_ executable: String, _ arguments: [String] = [],
                             environment: [String: String]? = nil,
                             currentDirectory: URL? = nil,
                             timeout: Duration? = nil) async throws -> Result {
        let result = try await run(executable, arguments, environment: environment,
                                   currentDirectory: currentDirectory, timeout: timeout)
        guard result.succeeded else {
            throw Failure.failed(command: ([executable] + arguments).joined(separator: " "),
                                 status: result.status, stderr: result.err)
        }
        return result
    }

    private static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Minimal box so the pipe readers can hand their bytes back to the continuation. The two
/// writers touch distinct boxes and are joined by the DispatchGroup before either is read.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// `terminationHandler` and a timeout can both fire; the continuation must resume once.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let pending: CheckedContinuation<T, Error>?
        lock.lock()
        pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let pending: CheckedContinuation<T, Error>?
        lock.lock()
        pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
