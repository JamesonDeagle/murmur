import Foundation
import FluidAudio

/// Parakeet TDT v3 backend via FluidAudio + Core ML on Apple Neural Engine.
///
/// Multilingual (25 European languages + Japanese + Chinese) with automatic
/// language detection — no equivalent to the Russian-hardcode workaround
/// `WhisperEngine` needs. Runs entirely on the ANE: ~66 MB working memory,
/// ~110× real-time factor on M-series, and crucially leaves the Metal GPU
/// free for other workloads (Xcode builds, games, video editing).
///
/// FluidAudio's `AsrManager` is itself an actor; we wrap it in our own actor
/// to satisfy the SpeechEngine protocol and to keep the model load /
/// transcribe / cleanup lifecycle parallel to `WhisperEngine`.
actor ParakeetEngine: SpeechEngine {
    private var asrManager: AsrManager?
    private var asrModels: AsrModels?

    /// Translate FluidAudio's `DownloadUtils.DownloadProgress` (fraction + phase enum)
    /// into our shared `Murmur.DownloadProgress`. Byte counts aren't available
    /// from FluidAudio — we report -1 / 0 there so the UI falls back to its
    /// "fraction + phase" rendering branch.
    private static func mapProgress(
        _ p: DownloadUtils.DownloadProgress
    ) -> DownloadProgress {
        let phase: String
        switch p.phase {
        case .listing:
            phase = "Listing files"
        case .downloading(let done, let total):
            phase = "Downloading \(done)/\(total)"
        case .compiling(let modelName):
            phase = "Compiling \(modelName)"
        }
        return DownloadProgress(
            modelName: "parakeet",
            bytesDownloaded: -1,
            totalBytes: -1,
            bytesPerSecond: 0,
            fraction: p.fractionCompleted,
            phase: phase
        )
    }

    func loadModel(
        name: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async {
        mlog("ParakeetEngine.loadModel: \(name)")

        // If we already have a manager loaded, free it first so we don't
        // double-allocate the ANE residency budget.
        if let oldManager = asrManager {
            await oldManager.cleanup()
            asrManager = nil
            asrModels = nil
        }

        do {
            // .v3 is the only version we ship — multilingual model.
            // progressHandler is called on an unspecified queue per FluidAudio docs.
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { progress in
                    onProgress?(Self.mapProgress(progress))
                }
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            self.asrModels = models
            self.asrManager = manager

            mlog("ParakeetEngine: model loaded and ready")
        } catch {
            mlog("ParakeetEngine.loadModel failed: \(error)")
            asrManager = nil
            asrModels = nil
        }
    }

    func transcribe(audio: [Float]) async -> String? {
        guard !audio.isEmpty else { return nil }
        guard let manager = asrManager else {
            mlog("ParakeetEngine.transcribe: no manager loaded")
            return nil
        }

        // Audio level sanity log — same line shape as WhisperEngine so log
        // grep across engines stays consistent.
        let maxVal = audio.map { abs($0) }.max() ?? 0
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
        mlog("ParakeetEngine.transcribe: \(audio.count) samples, max=\(maxVal), rms=\(rms)")

        do {
            // Fresh decoder state per dictation utterance. We don't run streaming
            // here — each Option+Space session is independent, so there's nothing
            // useful to carry over between them.
            var decoderState = try TdtDecoderState(decoderLayers: 2)
            // language: nil → FluidAudio auto-detects (English / Russian / etc).
            let result = try await manager.transcribe(audio, decoderState: &decoderState, language: nil)
            mlog("Parakeet result: text='\(result.text.prefix(80))' conf=\(result.confidence) rtfx=\(result.rtfx)")
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            mlog("ParakeetEngine.transcribe failed: \(error)")
            return nil
        }
    }

    func cleanup() async {
        if let manager = asrManager {
            await manager.cleanup()
        }
        asrManager = nil
        asrModels = nil
        mlog("ParakeetEngine cleaned up")
    }

    func cachedModelPaths(name: String) async -> [URL] {
        // FluidAudio's documented default cache location
        // (see DownloadUtils.swift in their repo: "~/Library/Application
        // Support/FluidAudio/Models/").
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else { return [] }
        let dir = appSupport
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        return FileManager.default.fileExists(atPath: dir.path) ? [dir] : []
    }
}
