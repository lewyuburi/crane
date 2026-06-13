import Foundation

struct ProcessResult {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

/// Reference box so the stderr reader thread and the awaiting code share one Data
/// instance safely (the DispatchGroup barrier orders the write before the read).
private final class DataBox: @unchecked Sendable {
    var value = Data()
}

/// Runs external processes WITHOUT blocking Swift's cooperative thread pool.
///
/// `Process.waitUntilExit()` / `readDataToEndOfFile()` block the calling thread.
/// Doing that inside `async` code (or an actor) starves the small cooperative pool
/// and freezes the whole app. So we do the blocking work on a global dispatch queue
/// and bridge back to async with a continuation — the awaiting task suspends, it
/// never blocks a worker thread.
enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                // Drain stderr on its own thread so a full stderr pipe buffer (64KB)
                // can't deadlock against us draining stdout, and vice versa.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                cont.resume(returning: ProcessResult(
                    stdout: outData, stderr: errBox.value, status: process.terminationStatus
                ))
            }
        }
    }
}
