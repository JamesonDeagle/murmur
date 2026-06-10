import Foundation

/// Generic speech-to-text engine contract. One concrete actor implements it:
///   - `WhisperEngine`     — whisper.cpp + Metal (turbo / large variants).
///
/// The protocol intentionally stays minimal so adding a new backend (e.g. an
/// MLX port, a remote API) only requires implementing three methods. Extra
/// engines (Parakeet on ANE, Voxtral/Qwen3 on MLX) were stripped for the
/// first Mac App Store submission to drop the external FluidAudio / MLX
/// dependencies and minimize App Review surface; they can return in an update.
protocol SpeechEngine: Actor {
    /// Download (if needed) and initialize a model. `name` is engine-specific:
    /// "turbo" / "large" for whisper.
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

/// Snapshot of an in-flight model download / load. whisper.cpp goes through
/// `ProgressDownloader` and has exact byte counts + smoothed bytes/sec. The
/// `fraction` / `phase` fields are kept generic so a future fraction-only
/// engine (no byte counts) can reuse this struct without changes.
///
/// Use `hasByteCount` in the UI to pick a presentation:
///   - `true`  → "245 MB / 1,5 GB · 12 MB/s · ETA 1m32s"  (whisper)
///   - `false` → "Downloading  40%"                        (fraction-only)
struct DownloadProgress: Sendable, Equatable {
    let modelName: String
    let bytesDownloaded: Int64     // -1 when the engine doesn't report bytes
    let totalBytes: Int64          // -1 when unknown
    let bytesPerSecond: Double     // 0 when unknown
    let fraction: Double           // 0–1, always valid
    let phase: String              // e.g. "Downloading", "Compiling"

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
/// `AppState.activeModel`). After A/B testing all engines on real Russian
/// dictation, whisper-large-v3-turbo via whisper.cpp + Metal gave the best
/// transcription quality.
///
/// The first Mac App Store submission ships whisper-only (turbo + large) to
/// drop the external FluidAudio / MLX dependencies; the Parakeet (ANE) and
/// Voxtral/Qwen3 (MLX) engines were removed and can return in an update.
enum SpeechModelOption: String, CaseIterable, Sendable, Identifiable {
    /// whisper-large-v3-turbo via whisper.cpp + Metal — best transcription
    /// quality on Russian audio in our tests. ~1.5 GB on disk, 1–2s per phrase.
    /// **Default for new installs.** Russian-only by default
    /// (whisper.cpp 1.8.4 detect_language bug).
    case whisperTurbo = "turbo"
    /// whisper-large-v3 via whisper.cpp + Metal — full large model, ~3 GB,
    /// Russian-only by default. Slower than turbo but higher accuracy ceiling.
    case whisperLarge = "large"

    var id: String { rawValue }

    var engineKind: EngineKind {
        switch self {
        case .whisperTurbo, .whisperLarge: return .whisper
        }
    }

    /// String passed into `SpeechEngine.loadModel(name:)`. For whisper variants
    /// this picks the .bin file.
    var engineModelName: String {
        switch self {
        case .whisperTurbo:    return "turbo"
        case .whisperLarge:    return "large"
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
        case .whisperLarge:
            return t("whisper-large-v3  ·  3.0 GB  ·  Russian",
                  ru: "whisper-large-v3  ·  3,0 ГБ  ·  русский")
        }
    }

    /// Used in the menubar status line ("Loading turbo…", "Resume turbo").
    var shortName: String {
        switch self {
        case .whisperTurbo:    return "turbo"
        case .whisperLarge:    return "large"
        }
    }
}

/// Backend identifier — used to decide whether a model switch reuses the
/// current engine actor or replaces it. whisper.cpp owns heavy native state
/// (whisper.cpp context, Metal GPU buffers). Only one kind ships today;
/// the enum is kept so re-introducing extra backends later stays a small,
/// additive change.
enum EngineKind: Sendable {
    case whisper      // whisper.cpp + Metal GPU

    @MainActor
    func makeEngine() -> any SpeechEngine {
        switch self {
        case .whisper:     return WhisperEngine()
        }
    }
}
