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
/// and `parakeetV3` is the **default model for new installs** (see
/// `AppState.activeModel`). Parakeet runs on the ANE, takes ~25× less RAM
/// than whisper, and auto-detects 25 EU + JP + ZH languages — for the vast
/// majority of users it's the right pick.
enum SpeechModelOption: String, CaseIterable, Sendable, Identifiable {
    /// Parakeet TDT v3 via Core ML on Apple Neural Engine — multilingual (25 EU langs + JP/ZH),
    /// auto language detection, ~600 MB on disk, ~66 MB working memory, ~110× RTF on M-series.
    /// **Default for new installs.**
    case parakeetV3 = "parakeet"
    /// whisper-large-v3-turbo via WhisperKit (Argmax) on Core ML / Apple Neural Engine — whisper
    /// quality with ANE residency. ~626 MB, ~42× RTF on M-series ANE-only. Working
    /// language auto-detection (unlike whisper.cpp 1.8.4). Best of both worlds.
    case whisperKitTurbo = "whisper-ane"
    /// whisper-large-v3-turbo via whisper.cpp + Metal — fast, ~1.5 GB, Russian-only by default.
    case whisperTurbo = "turbo"
    /// whisper-large-v3 via whisper.cpp + Metal — best whisper quality, ~3 GB, Russian-only by default.
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
        case .whisperKitTurbo:      return .whisperKit
        case .voxtralMini, .qwen3Asr: return .mlxAudio
        }
    }

    /// String passed into `SpeechEngine.loadModel(name:)`. For whisper variants
    /// this picks the .bin file; for Parakeet and WhisperKit it's informational
    /// (single-variant for now); for MLX-Audio it picks Voxtral vs Qwen3.
    var engineModelName: String {
        switch self {
        case .whisperTurbo:    return "turbo"
        case .whisperLarge:    return "large"
        case .parakeetV3:      return "parakeet"
        case .whisperKitTurbo: return "whisper-ane"
        case .voxtralMini:     return "voxtral"
        case .qwen3Asr:        return "qwen3"
        }
    }

    /// Label shown in the menu next to the radio checkmark.
    var menuLabel: String {
        switch self {
        case .parakeetV3:      return "parakeet  ·  ANE, multilingual, ~600 MB  (recommended)"
        case .whisperKitTurbo: return "whisper-ane  ·  whisper-large-v3 on ANE, ~626 MB, multilingual"
        case .voxtralMini:     return "voxtral  ·  Mistral 4B (MLX/GPU), ~2 GB, experimental"
        case .qwen3Asr:        return "qwen3  ·  Alibaba 1.7B (MLX/GPU), 52 langs, ~3.4 GB, experimental"
        case .whisperTurbo:    return "turbo  ·  whisper.cpp + Metal, ~1.5 GB, Russian"
        case .whisperLarge:    return "large  ·  whisper.cpp + Metal, ~3 GB, Russian"
        }
    }

    /// Used in the menubar status line ("Loading turbo…", "Resume parakeet").
    var shortName: String {
        switch self {
        case .whisperTurbo:    return "turbo"
        case .whisperLarge:    return "large"
        case .parakeetV3:      return "parakeet"
        case .whisperKitTurbo: return "whisper-ane"
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
    case whisperKit   // Argmax WhisperKit + Core ML + ANE
    case mlxAudio     // mlx-audio-swift + MLX + Apple Silicon GPU (Voxtral, Qwen3)

    @MainActor
    func makeEngine() -> any SpeechEngine {
        switch self {
        case .whisper:     return WhisperEngine()
        case .parakeet:    return ParakeetEngine()
        case .whisperKit:  return WhisperKitEngine()
        case .mlxAudio:    return MLXAudioEngine()
        }
    }
}
