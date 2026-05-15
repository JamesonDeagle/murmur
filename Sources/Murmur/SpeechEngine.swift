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
    /// whisper-large-v3-turbo via whisper.cpp + Metal — fast, ~1.5 GB, Russian-only by default.
    case whisperTurbo = "turbo"
    /// whisper-large-v3 via whisper.cpp + Metal — best whisper quality, ~3 GB, Russian-only by default.
    case whisperLarge = "large"

    var id: String { rawValue }

    var engineKind: EngineKind {
        switch self {
        case .whisperTurbo, .whisperLarge: return .whisper
        case .parakeetV3: return .parakeet
        }
    }

    /// String passed into `SpeechEngine.loadModel(name:)`. For whisper variants
    /// this picks the .bin file; for Parakeet it's informational only (v3 is the
    /// only variant the engine knows about).
    var engineModelName: String {
        switch self {
        case .whisperTurbo: return "turbo"
        case .whisperLarge: return "large"
        case .parakeetV3:   return "parakeet"
        }
    }

    /// Label shown in the menu next to the radio checkmark.
    var menuLabel: String {
        switch self {
        case .parakeetV3:   return "parakeet  ·  ANE, multilingual, ~600 MB  (recommended)"
        case .whisperTurbo: return "turbo  ·  whisper, ~1.5 GB, Russian"
        case .whisperLarge: return "large  ·  whisper, ~3 GB, Russian"
        }
    }

    /// Used in the menubar status line ("Loading turbo…", "Resume parakeet").
    var shortName: String {
        switch self {
        case .whisperTurbo: return "turbo"
        case .whisperLarge: return "large"
        case .parakeetV3:   return "parakeet"
        }
    }
}

/// Backend identifier — used to decide whether a model switch reuses the
/// current engine actor or replaces it (whisper context ≠ parakeet context).
enum EngineKind: Sendable {
    case whisper
    case parakeet

    @MainActor
    func makeEngine() -> any SpeechEngine {
        switch self {
        case .whisper:  return WhisperEngine()
        case .parakeet: return ParakeetEngine()
        }
    }
}
