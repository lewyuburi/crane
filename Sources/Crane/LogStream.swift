import Foundation
import Observation

/// Drives a `container logs --follow` process and accumulates output for the UI.
@MainActor
@Observable
final class LogStream {
    private(set) var text: String = ""
    private(set) var isRunning = false
    var errorMessage: String?

    private var process: Process?
    private let containerID: String

    init(containerID: String) {
        self.containerID = containerID
    }

    func start(follow: Bool = true, tail: Int? = 200) {
        guard process == nil else { return }
        text = ""
        isRunning = true
        Task { await run(follow: follow, tail: tail) }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func run(follow: Bool, tail: Int?) async {
        do {
            let proc = try await ContainerCLI.shared.logProcess(id: containerID, follow: follow, tail: tail)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            self.process = proc

            let handle = pipe.fileHandleForReading
            // Stream chunks as they arrive off a background reader; hop to main to append.
            handle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty else {
                    fh.readabilityHandler = nil
                    return
                }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.text += chunk }
            }

            // Suspend (do NOT block the main thread) until the process exits. With
            // --follow this can be a long time; waitUntilExit() here would freeze the app.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proc.terminationHandler = { _ in cont.resume() }
                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
            handle.readabilityHandler = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isRunning = false
        process = nil
    }
}
