import Foundation
import Observation

/// Drives `container image pull --progress plain` and parses its progress lines
/// (e.g. `[1/2] Fetching image 41% (30 of 49 blobs, 9,3/22,2 MB, 2,5 MB/s) [7s]`).
@MainActor
@Observable
final class ImagePuller {
    private(set) var statusLine = ""
    private(set) var fraction: Double = 0
    private(set) var isPulling = false
    private(set) var didFinish = false
    var errorMessage: String?

    private var process: Process?
    private var readHandle: FileHandle?

    func pull(reference: String) {
        guard process == nil, !reference.isEmpty else { return }
        isPulling = true
        didFinish = false
        errorMessage = nil
        statusLine = "Starting…"
        fraction = 0
        Task { await run(reference: reference) }
    }

    func cancel() {
        readHandle?.readabilityHandler = nil   // or the pipe keeps firing after we drop the process
        readHandle = nil
        process?.terminate()
        process = nil
        isPulling = false
    }

    private func run(reference: String) async {
        do {
            let proc = try await ContainerCLI.shared.pullProcess(reference: reference)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            self.process = proc

            let handle = pipe.fileHandleForReading
            self.readHandle = handle
            handle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty else { fh.readabilityHandler = nil; return }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.consume(chunk) }
            }

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proc.terminationHandler = { _ in cont.resume() }
                do { try proc.run() } catch { proc.terminationHandler = nil; cont.resume(throwing: error) }
            }
            handle.readabilityHandler = nil
            readHandle = nil

            if proc.terminationStatus == 0 {
                fraction = 1
                statusLine = "Done"
                didFinish = true
            } else {
                errorMessage = statusLine.isEmpty ? "Pull failed (exit \(proc.terminationStatus))" : statusLine
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isPulling = false
        process = nil
    }

    private func consume(_ chunk: String) {
        // Progress is line- (and carriage-return-) delimited; take the last non-empty token.
        let parts = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        guard let last = parts.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        let text = String(last).trimmingCharacters(in: .whitespaces)
        statusLine = text
        if let range = text.range(of: #"(\d+)%"#, options: .regularExpression) {
            let digits = text[range].dropLast()  // strip "%"
            if let pct = Double(digits) { fraction = pct / 100 }
        }
    }
}
