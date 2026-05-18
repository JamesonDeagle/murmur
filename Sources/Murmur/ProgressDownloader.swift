import Foundation

/// Downloads a file via URLSession with progress callbacks (bytes + smoothed
/// MB/s speed). Returns a temp URL — caller is responsible for moving the file
/// into its final location.
///
/// Why this exists: `URLSession.shared.download(from:)` (the simple async API)
/// gives you no progress events. For a 3 GB whisper-large download that means
/// the menubar UI sits on "Loading model..." for minutes with no feedback.
/// `URLSessionDownloadDelegate` exposes per-chunk byte counts which we feed
/// into a `DownloadProgress` callback (throttled to ~5 updates/sec).
enum ProgressDownloader {
    static func download(
        url: URL,
        modelName: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = Delegate(
                modelName: modelName,
                onProgress: onProgress,
                continuation: continuation
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            // Hold the session alive via the delegate so it isn't deallocated
            // before delegate callbacks fire.
            delegate.session = session
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let modelName: String
        let onProgress: (@Sendable (DownloadProgress) -> Void)?
        var continuation: CheckedContinuation<URL, Error>?
        var session: URLSession?

        // EMA + throttling state
        private var emaBytesPerSecond: Double = 0
        private var lastTickTime: Date = .init()
        private var lastTickBytes: Int64 = 0
        private var lastEmittedTime: Date = .distantPast
        private var startTime: Date?

        init(
            modelName: String,
            onProgress: (@Sendable (DownloadProgress) -> Void)?,
            continuation: CheckedContinuation<URL, Error>
        ) {
            self.modelName = modelName
            self.onProgress = onProgress
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let now = Date()
            if startTime == nil {
                startTime = now
                lastTickTime = now
                lastTickBytes = totalBytesWritten
            }

            // Update instantaneous speed against last tick (~10x/sec from URLSession),
            // then smooth via EMA so the UI doesn't jitter.
            let dt = now.timeIntervalSince(lastTickTime)
            if dt >= 0.2 {
                let dBytes = totalBytesWritten - lastTickBytes
                let instant = Double(dBytes) / dt
                // EMA with a ~1.5s effective window
                let alpha = 0.3
                emaBytesPerSecond = emaBytesPerSecond == 0
                    ? instant
                    : alpha * instant + (1 - alpha) * emaBytesPerSecond
                lastTickTime = now
                lastTickBytes = totalBytesWritten
            }

            // Throttle UI updates to ~5/sec — the @Published change cascades through
            // SwiftUI body re-evaluation, no point firing on every chunk.
            if now.timeIntervalSince(lastEmittedTime) >= 0.2 {
                lastEmittedTime = now
                let frac: Double = totalBytesExpectedToWrite > 0
                    ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                    : 0
                let progress = DownloadProgress(
                    modelName: modelName,
                    bytesDownloaded: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite,
                    bytesPerSecond: emaBytesPerSecond,
                    fraction: frac,
                    phase: t("Downloading", ru: "Скачивание")
                )
                onProgress?(progress)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // `location` is auto-deleted when this callback returns. Move it to
            // a stable temp location now; the engine will `moveItem` from there
            // to the final models directory.
            let stableTemp = FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur-model-\(UUID().uuidString).bin")
            do {
                try FileManager.default.moveItem(at: location, to: stableTemp)

                // Emit a final 100% progress event so the UI reads "1.5 GB / 1.5 GB"
                if let total = downloadTask.response?.expectedContentLength, total > 0 {
                    onProgress?(DownloadProgress(
                        modelName: modelName,
                        bytesDownloaded: total,
                        totalBytes: total,
                        bytesPerSecond: emaBytesPerSecond,
                        fraction: 1.0,
                        phase: t("Downloading", ru: "Скачивание")
                    ))
                }

                continuation?.resume(returning: stableTemp)
                continuation = nil
            } catch {
                continuation?.resume(throwing: error)
                continuation = nil
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            // Success path is handled in didFinishDownloadingTo. This fires for errors
            // (network drop, 404, etc.) — surface them to the awaiter.
            if let error = error, continuation != nil {
                continuation?.resume(throwing: error)
                continuation = nil
                session.finishTasksAndInvalidate()
            }
        }
    }
}
