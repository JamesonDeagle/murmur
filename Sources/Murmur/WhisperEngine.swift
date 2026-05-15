import Foundation
import CWhisper

/// whisper.cpp-backed speech engine. Handles both turbo and large variants
/// — the variant is chosen via the `name` parameter to `loadModel`.
///
/// Renamed from `TranscriptionEngine` in v3.4 when Parakeet was added as a
/// second backend. The `SpeechEngine` protocol now lives in SpeechEngine.swift
/// along with the shared `DownloadProgress` struct.
actor WhisperEngine: SpeechEngine {
    private var ctx: OpaquePointer?
    private let modelsDir: URL

    private let models: [String: String] = [
        "turbo": "ggml-large-v3-turbo.bin",
        "large": "ggml-large-v3.bin",
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDir = appSupport.appendingPathComponent("Murmur/models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    func loadModel(
        name: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async {
        mlog("WhisperEngine.loadModel: \(name)")

        // CRITICAL: nil out BEFORE free so any concurrent transcribe() call
        // suspended on this actor's queue sees nil instead of a dangling pointer.
        // Without this, switching models (especially while a slow download is
        // in flight on `await downloadModel`) caused EXC_BAD_ACCESS in
        // whisper_full when Option+Space was pressed mid-switch.
        if let oldCtx = ctx {
            ctx = nil
            whisper_free(oldCtx)
        }

        guard let filename = models[name] else {
            mlog("WhisperEngine.loadModel: unknown model name '\(name)'")
            return
        }
        let modelPath = modelsDir.appendingPathComponent(filename)

        // Download model if not present (large is ~3GB — can take minutes)
        if !FileManager.default.fileExists(atPath: modelPath.path) {
            mlog("WhisperEngine.loadModel: downloading '\(name)' to \(modelPath.path)")
            await downloadModel(name: name, to: modelPath, onProgress: onProgress)
            // Verify download succeeded — partial/failed download leaves no file
            guard FileManager.default.fileExists(atPath: modelPath.path) else {
                mlog("WhisperEngine.loadModel: download failed, no model file at \(modelPath.path)")
                return
            }
        }

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = false

        mlog("Loading whisper model from: \(modelPath.path)")
        ctx = whisper_init_from_file_with_params(modelPath.path, params)
        mlog("whisper_init result: \(ctx != nil ? "OK" : "FAILED")")

        // Warmup
        if ctx != nil {
            let silence = [Float](repeating: 0, count: 16000)
            _ = transcribeRaw(samples: silence)
            print("Whisper model '\(name)' loaded and warmed up")
        }
    }

    func transcribe(audio: [Float]) async -> String? {
        guard !audio.isEmpty else { return nil }

        // Check audio levels
        let maxVal = audio.map { abs($0) }.max() ?? 0
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
        mlog("WhisperEngine.transcribe: \(audio.count) samples, max=\(maxVal), rms=\(rms)")

        return transcribeRaw(samples: audio)
    }

    private func transcribeRaw(samples: [Float]) -> String? {
        guard let ctx = ctx else { return nil }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = true
        params.no_context = true
        params.suppress_blank = false

        // Bug in whisper.cpp 1.8.4: detect_language=true + language="auto" produces 0 segments
        // Use explicit language instead
        let langStr = strdup("ru")
        params.language = UnsafePointer(langStr)
        params.detect_language = false

        let promptStr = strdup("Здравствуйте. Вот, что я хотел сказать: Hello, my name is Anton.")
        params.initial_prompt = UnsafePointer(promptStr)

        mlog("whisper_full starting with \(samples.count) samples...")
        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(samples.count))
        }

        free(langStr)
        free(promptStr)

        mlog("whisper_full result: \(result)")
        guard result == 0 else { return nil }

        let nSegments = whisper_full_n_segments(ctx)
        mlog("Segments: \(nSegments)")
        var text = ""
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                let segText = String(cString: cStr)
                mlog("  seg[\(i)]: \(segText)")
                text += segText
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downloadModel(
        name: String,
        to localPath: URL,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async {
        let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
        guard let filename = models[name],
              let url = URL(string: "\(baseURL)/\(filename)") else { return }

        print("Downloading model '\(name)' from \(url)...")

        do {
            let tempURL = try await ProgressDownloader.download(
                url: url,
                modelName: name,
                onProgress: onProgress
            )
            // Make sure target directory exists, then move into place
            try? FileManager.default.removeItem(at: localPath)
            try FileManager.default.moveItem(at: tempURL, to: localPath)
            mlog("Whisper model downloaded: \(localPath.path)")
        } catch {
            mlog("Failed to download whisper model: \(error)")
        }
    }

    func cleanup() async {
        if let ctx = ctx {
            whisper_free(ctx)
            self.ctx = nil
        }
    }
}
