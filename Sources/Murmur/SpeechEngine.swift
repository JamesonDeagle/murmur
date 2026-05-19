import Foundation

/// Generic speech-to-text engine contract. Two concrete actors implement it:
///   - `WhisperEngine`     — whisper.cpp + Metal (turbo / large variants).
///   - `ParakeetEngine`    — Parakeet TDT v3 via Core ML on Apple Neural Engine.
///
/// The protocol intentionally stays minimal so adding a new backend (e.g. an
/// MLX port, a remote API) only requires implementing three methods.
protocol SpeechEngine: Actor {
    /// Download (if needed) and initialize a model. `name` is engine-specific:
    /// "turbo" / "large" for whisper, ignored for parakeet (single-variant v3).
    /// `onProgress` is called from a background queue — wrap MainActor updates yourself.
    func loadModel(
        name: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async

    /// Transcribe a 16 kHz mono Float32 audio buffer. Returns nil on empty input
    /// or engine failure (also logged via `mlog`).
    func transcribe(audio: [Float]) async -> String?

    /// Free the in-memory model (CPU RAM + ANE/GPU buffers). Caller is expected
    /// to drop the actor reference afterwards if a full reset is wanted.
    func cleanup() async

    /// On-disk locations this engine uses to cache `name`. Used by AppState's
    /// stale-model cleanup to delete models that haven't been used in N days.
    /// Returns only paths that actually exist; an empty array means either
    /// "not downloaded" or "we can't safely delete this engine's cache" and
    /// the cleanup will skip the model.
    func cachedModelPaths(name: String) async -> [URL]
}

extension SpeechEngine {
    /// Default: this engine doesn't expose its cache layout, skip cleanup.
    /// Concrete engines override when they know their cache location.
    func cachedModelPaths(name: String) async -> [URL] { [] }
}

// MARK: - Download progress

/// Snapshot of an in-flight model download / load. Two engines emit different
/// information: whisper.cpp goes through `ProgressDownloader` and has exact
/// byte counts + smoothed bytes/sec; Parakeet/FluidAudio reports a fraction
/// (0–1) and a phase string ("Downloading 2/5", "Compiling encoder", …).
///
/// Use `hasByteCount` in the UI to pick a presentation:
///   - `true`  → "245 MB / 1,5 GB · 12 MB/s · ETA 1m32s"  (whisper)
///   - `false` → "Downloading 2/5  40%"                     (parakeet)
struct DownloadProgress: Sendable, Equatable {
    let modelName: String
    let bytesDownloaded: Int64     // -1 when the engine doesn't report bytes
    let totalBytes: Int64          // -1 when unknown
    let bytesPerSecond: Double     // 0 when unknown
    let fraction: Double           // 0–1, always valid
    let phase: String              // e.g. "Downloading", "Compiling parakeet_encoder"

    var hasByteCount: Bool { totalBytes > 0 }

    var fractionPercent: Int {
        Int((max(0.0, min(1.0, fraction)) * 100).rounded())
    }

    var etaSeconds: Double? {
        guard totalBytes > 0, bytesPerSecond > 0 else { return nil }
        let remaining = max(0, totalBytes - bytesDownloaded)
        return Double(remaining) / bytesPerSecond
    }
}

// MARK: - User-facing model catalogue

/// What the user picks in the Model menu. Each option knows which engine to
/// instantiate and which variant name to pass into `loadModel`.
///
/// Declaration order matters: `allCases` is what populates the Model menu,
/// and `whisperTurbo` is the **default model for new installs** (see
/// `AppState.activeModel`). After A/B testing all six engines in v3.10 on
/// real Russian dictation, whisper-large-v3-turbo via whisper.cpp + Metal
/// gave the best transcription quality. Parakeet stays at #2 — it's the
/// fastest and lightest, recommended when whisper is overkill.
enum SpeechModelOption: String, CaseIterable, Sendable, Identifiable {
    /// whisper-large-v3-turbo via whisper.cpp + Metal — best transcription
    /// quality on Russian audio in our tests. ~1.5 GB on disk, 1–2s per phrase.
    /// **Default for new installs.** Russian-only by default
    /// (whisper.cpp 1.8.4 detect_language bug).
    case whisperTurbo = "turbo"
    /// Parakeet TDT v3 via Core ML on Apple Neural Engine — multilingual
    /// (25 EU langs + JP/ZH), auto language detection, ~600 MB on disk,
    /// ~66 MB working memory, ~110× RTF. Best lightweight alternative.
    case parakeetV3 = "parakeet"
    /// whisper-large-v3 via whisper.cpp + Metal — full large model, ~3 GB,
    /// Russian-only by default. Slower than turbo but higher accuracy ceiling.
    case whisperLarge = "large"
    /// Voxtral Mini 4B Realtime (Mistral AI) via MLX. Biggest model we ship.
    /// 4-bit quantization on disk (~2 GB), runs on Apple Silicon GPU via MLX.
    /// Experimental / evaluation.
    case voxtralMini = "voxtral"
    /// Qwen3-ASR-1.7B (Alibaba, January 2026) via MLX. 52 languages including
    /// Russian + Ukrainian. bf16 on disk (~3.4 GB). Experimental / evaluation.
    case qwen3Asr = "qwen3"

    var id: String { rawValue }

    var engineKind: EngineKind {
        switch self {
        case .whisperTurbo, .whisperLarge: return .whisper
        case .parakeetV3:           return .parakeet
        case .voxtralMini, .qwen3Asr: return .mlxAudio
        }
    }

    /// String passed into `SpeechEngine.loadModel(name:)`. For whisper variants
    /// this picks the .bin file; for Parakeet it's informational
    /// (single-variant for now); for MLX-Audio it picks Voxtral vs Qwen3.
    var engineModelName: String {
        switch self {
        case .whisperTurbo:    return "turbo"
        case .whisperLarge:    return "large"
        case .parakeetV3:      return "parakeet"
        case .voxtralMini:     return "voxtral"
        case .qwen3Asr:        return "qwen3"
        }
    }

    /// Label shown in the menu next to the radio checkmark.
    ///
    /// Compact shape:
    ///   <model + params>  ·  <size>  ·  <languages>  [·  <tag>]
    ///
    /// Localized to the system language.
    var menuLabel: String {
        switch self {
        case .whisperTurbo:
            return t("whisper-large-v3-turbo  ·  1.5 GB  ·  Russian  ·  recommended",
                  ru: "whisper-large-v3-turbo  ·  1,5 ГБ  ·  русский  ·  рекомендуется")
        case .parakeetV3:
            return t("Parakeet TDT v3  ·  600 MB  ·  28 languages",
                  ru: "Parakeet TDT v3  ·  600 МБ  ·  28 языков")
        case .whisperLarge:
            return t("whisper-large-v3  ·  3.0 GB  ·  Russian",
                  ru: "whisper-large-v3  ·  3,0 ГБ  ·  русский")
        case .voxtralMini:
            return t("Voxtral Mini 4B  ·  2.0 GB  ·  multilingual  ·  experimental",
                  ru: "Voxtral Mini 4B  ·  2,0 ГБ  ·  многоязычная  ·  экспериментальная")
        case .qwen3Asr:
            return t("Qwen3-ASR 1.7B  ·  3.4 GB  ·  52 languages  ·  experimental",
                  ru: "Qwen3-ASR 1,7B  ·  3,4 ГБ  ·  52 языка  ·  экспериментальная")
        }
    }

    /// Used in the menubar status line ("Loading turbo…", "Resume parakeet").
    var shortName: String {
        switch self {
        case .whisperTurbo:    return "turbo"
        case .whisperLarge:    return "large"
        case .parakeetV3:      return "parakeet"
        case .voxtralMini:     return "voxtral"
        case .qwen3Asr:        return "qwen3"
        }
    }
}

/// Backend identifier — used to decide whether a model switch reuses the
/// current engine actor or replaces it. Each kind owns heavy native state
/// (whisper.cpp context, Core ML model bundles, ANE residency) that doesn't
/// coexist gracefully.
enum EngineKind: Sendable {
    case whisper      // whisper.cpp + Metal GPU
    case parakeet     // FluidAudio + Core ML + ANE
    case mlxAudio     // mlx-audio-swift + MLX + Apple Silicon GPU (Voxtral, Qwen3)

    @MainActor
    func makeEngine() -> any SpeechEngine {
        switch self {
        case .whisper:     return WhisperEngine()
        case .parakeet:    return ParakeetEngine()
        case .mlxAudio:    return MLXAudioEngine()
        }
    }
}
