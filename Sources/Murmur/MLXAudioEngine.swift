import Foundation
// mlx-audio-swift's public types are not annotated for Swift 6 strict
// concurrency (Module-derived models are reference types passed through
// our actor). @preconcurrency keeps the build green without doing any
// real concurrency damage — the model instance never escapes this actor.
@preconcurrency import MLX
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXAudioCore

/// MLX-Audio Swift backend for two large multilingual ASR models we're
/// currently evaluating:
///
///   - **Voxtral Mini 4B Realtime** (Mistral AI) — biggest model we ship,
///     ~2 GB on disk in 4-bit, multilingual, runs on the GPU/MPS via MLX.
///   - **Qwen3-ASR-1.7B** (Alibaba, January 2026) — 52 languages including
///     Russian and Ukrainian, ~3.4 GB on disk in bf16.
///
/// Both implement the same `STTGenerationModel` protocol so this single
/// actor handles them through a `Variant` enum. Apple's MLX runs on the
/// integrated GPU (Metal Performance Shaders) — different compute pool
/// from Parakeet/WhisperKit which sit on the ANE. Mind the trade-off:
/// MLX models can be larger and more accurate, but they actively use the
/// GPU during inference.
actor MLXAudioEngine: SpeechEngine {
    enum Variant {
        case voxtralMini4B
        case qwen3Asr17B

        /// Hugging Face repo ID. Quantization choice tuned for the
        /// disk/quality balance: Voxtral at 4 bits (still very capable),
        /// Qwen3 at bf16 (smaller base model, no need to quantize).
        var repoID: String {
            switch self {
            case .voxtralMini4B: return "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
            case .qwen3Asr17B:   return "mlx-community/Qwen3-ASR-1.7B-bf16"
            }
        }

        var humanName: String {
            switch self {
            case .voxtralMini4B: return "Voxtral Mini 4B"
            case .qwen3Asr17B:   return "Qwen3-ASR 1.7B"
            }
        }
    }

    /// Resolve a user-facing `name` ("voxtral" / "qwen3") to a Variant.
    /// Matches the raw values of `SpeechModelOption.voxtralMini` /
    /// `.qwen3Asr` so the routing AppState does is trivial.
    private static func variant(for name: String) -> Variant? {
        switch name {
        case "voxtral": return .voxtralMini4B
        case "qwen3":   return .qwen3Asr17B
        default: return nil
        }
    }

    // Existential wraps both VoxtralRealtimeModel and Qwen3ASRModel since
    // they share `STTGenerationModel`. We still dispatch by variant for
    // load-time (different static fromPretrained methods) and audio-format
    // quirks if they ever diverge.
    private var model: (any STTGenerationModel)?
    private var loaded: Variant?

    func loadModel(
        name: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async {
        mlog("MLXAudioEngine.loadModel: \(name)")

        guard let variant = Self.variant(for: name) else {
            mlog("MLXAudioEngine.loadModel: unknown variant '\(name)'")
            return
        }

        // Drop the previous model before loading another — MLX models hold
        // GPU buffers in addition to weights in RAM, and ARC release won't
        // happen automatically until we explicitly nil the reference.
        if model != nil {
            model = nil
            loaded = nil
        }

        // mlx-audio-swift's fromPretrained doesn't surface byte-level
        // download progress, so we emit a single coarse "loading" event
        // for the UI to render a fallback line.
        onProgress?(DownloadProgress(
            modelName: variant.humanName,
            bytesDownloaded: -1,
            totalBytes: -1,
            bytesPerSecond: 0,
            fraction: 0.0,
            phase: t("Downloading & loading", ru: "Скачивание и загрузка")
        ))

        do {
            switch variant {
            case .voxtralMini4B:
                let m = try await VoxtralRealtimeModel.fromPretrained(variant.repoID)
                self.model = m
            case .qwen3Asr17B:
                let m = try await Qwen3ASRModel.fromPretrained(variant.repoID)
                self.model = m
            }
            self.loaded = variant
            mlog("MLXAudioEngine: \(variant.humanName) loaded from \(variant.repoID)")
        } catch {
            mlog("MLXAudioEngine.loadModel failed for \(variant.humanName): \(error)")
            self.model = nil
            self.loaded = nil
        }
    }

    func transcribe(audio: [Float]) async -> String? {
        guard !audio.isEmpty else { return nil }
        guard let model = model, let variant = loaded else {
            mlog("MLXAudioEngine.transcribe: model not loaded")
            return nil
        }

        let maxVal = audio.map { abs($0) }.max() ?? 0
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
        mlog("MLXAudioEngine.transcribe (\(variant.humanName)): \(audio.count) samples, max=\(maxVal), rms=\(rms)")

        // Both Voxtral and Qwen3 expect a 1-D Float MLXArray of 16 kHz mono
        // audio in [-1, 1]. Our AudioRecorder produces exactly that.
        let audioArray = MLXArray(audio)

        // language: nil → let the model auto-detect. Other defaults
        // (temperature=0, maxTokens=8192) are fine for dictation.
        let params = STTGenerateParameters(
            temperature: 0.0,
            verbose: false,
            language: nil
        )

        let output: STTOutput = model.generate(
            audio: audioArray,
            generationParameters: params
        )

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = output.language.map { " detected=\($0)" } ?? ""
        mlog("MLXAudioEngine result (\(variant.humanName))\(detected): '\(text.prefix(80))'")
        return text.isEmpty ? nil : text
    }

    func cleanup() async {
        model = nil
        loaded = nil
        mlog("MLXAudioEngine cleaned up")
    }

    func cachedModelPaths(name: String) async -> [URL] {
        guard let variant = Self.variant(for: name) else { return [] }

        // HubCache.default.cacheDirectory → ~/.cache/huggingface/hub
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hubRoot = home.appendingPathComponent(".cache/huggingface/hub")

        // mlx-audio-swift unpacks the model under mlx-audio/<repo_with_underscores>/
        // (see ModelUtils.resolveOrDownloadModel in mlx-audio-swift source).
        let mlxSubdir = variant.repoID.replacingOccurrences(of: "/", with: "_")
        let mlxDir = hubRoot.appendingPathComponent("mlx-audio").appendingPathComponent(mlxSubdir)

        // Hugging Face hub also stores raw snapshots/blobs under models--<org>--<name>/
        let hubRepoDir = hubRoot.appendingPathComponent(
            "models--" + variant.repoID.replacingOccurrences(of: "/", with: "--")
        )

        var paths: [URL] = []
        if FileManager.default.fileExists(atPath: mlxDir.path) { paths.append(mlxDir) }
        if FileManager.default.fileExists(atPath: hubRepoDir.path) { paths.append(hubRepoDir) }
        return paths
    }
}
