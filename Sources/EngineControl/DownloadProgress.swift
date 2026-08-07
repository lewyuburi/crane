import Foundation

/// Reports download progress from `URLSession.download(from:delegate:)`.
///
/// Callbacks are throttled to whole percent steps: the UI can't show more than that, and every
/// call crosses an actor boundary.
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastReported = -1

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percent = Int(fraction * 100)
        lock.lock()
        let shouldReport = percent > lastReported
        if shouldReport { lastReported = percent }
        lock.unlock()
        if shouldReport { report(fraction) }
    }

    /// Required by the protocol; `download(from:delegate:)` hands us the file itself, so there is
    /// nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
