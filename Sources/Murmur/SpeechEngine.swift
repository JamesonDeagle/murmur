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

    /// Start a dictation. Drops anything left from the previous one.
    func beginSession() async

    /// Feed 16 kHz mono Float32 audio captured so far. Engines that can
    /// transcribe incrementally do that work here, while the user is still
    /// talking; the rest may simply accumulate.
    func append(_ samples: [Float]) async

    /// No more audio is coming. Returns the transcript of the whole take, or
    /// nil on empty input or engine failure (also logged via `mlog`).
    func endSession() async -> String?

    /// Dictation was cancelled — drop the take without transcribing it.
    func abortSession() async

    /// Select when transcription runs relative to the recording. Engines that
    /// can only work on a finished take ignore it.
    func setMode(_ mode: TranscriptionMode) async

    /// Free the in-memory model (CPU RAM + ANE/GPU buffers). Caller is expected
    /// to drop the actor reference afterwards if a full reset is wanted.
    func cleanup() async

    /// On-disk locations this engine uses to cache `name`. Used by AppState's
    /// stale-model cleanup to delete models that haven't been used in N days.
    /// Returns only paths that actually exist; an empty array means either
    /// "not downloaded" or "we can't safely delete this engine's cache" and
    /// the cleanup will skip the model.
    func cachedModelPaths(name: String) async -> [URL]

    /// Set the transcription language (whisper code like "en"/"ru").
    /// whisper.cpp 1.8.4's auto-detect is broken (detect_language=true yields
    /// 0 segments), so the language is always explicit — picked by the user in
    /// the Language menu, defaulting to the system locale.
    func setLanguage(_ code: String) async
}

extension SpeechEngine {
    /// Default: this engine doesn't expose its cache layout, skip cleanup.
    /// Concrete engines override when they know their cache location.
    func cachedModelPaths(name: String) async -> [URL] { [] }

    /// Default: engine has no language knob (e.g. auto-detecting backends).
    func setLanguage(_ code: String) async {}

    /// Default: engine transcribes finished takes only, so there is nothing
    /// to schedule.
    func setMode(_ mode: TranscriptionMode) async {}
}

// MARK: - Transcription languages

/// User-selectable transcription languages. whisper.cpp needs an explicit
/// language (auto-detect is broken in 1.8.4 — see WhisperEngine), so we ship
/// a curated list. The default follows the system locale when supported,
/// otherwise English — an App Review machine running English macOS gets
/// English out of the box, a Russian user gets Russian.
enum TranscriptionLanguage: String, CaseIterable, Sendable, Identifiable {
    case en, ru, de, es, fr, it, pt, uk

    var id: String { rawValue }

    /// Native-script label for the Language menu.
    var menuLabel: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .uk: return "Українська"
        }
    }

    /// Style-guide prompt fed to whisper as `initial_prompt` — nudges the
    /// decoder toward proper punctuation in the target language.
    var initialPrompt: String {
        switch self {
        case .en: return "Hello. Here is what I wanted to say: first, we review the plan; then, we ship it."
        case .ru: return "Здравствуйте. Вот, что я хотел сказать: Hello, my name is Anton."
        case .de: return "Hallo. Folgendes wollte ich sagen: zuerst der Plan, dann die Umsetzung."
        case .es: return "Hola. Esto es lo que quería decir: primero el plan, luego la entrega."
        case .fr: return "Bonjour. Voici ce que je voulais dire : d'abord le plan, ensuite la livraison."
        case .it: return "Ciao. Ecco cosa volevo dire: prima il piano, poi la consegna."
        case .pt: return "Olá. Aqui está o que eu queria dizer: primeiro o plano, depois a entrega."
        case .uk: return "Добрий день. Ось що я хотів сказати: спочатку план, потім реліз."
        }
    }

    /// Map a stored raw value back to a language; unknown/missing falls back
    /// to the system locale (if we support it), then English.
    static func resolve(_ raw: String?) -> TranscriptionLanguage {
        if let raw, let lang = TranscriptionLanguage(rawValue: raw) { return lang }
        return systemDefault
    }

    /// Best match for `Locale.preferredLanguages.first` among supported codes.
    static var systemDefault: TranscriptionLanguage {
        guard let preferred = Locale.preferredLanguages.first?.lowercased(),
              let code = preferred.split(separator: "-").first,
              let lang = TranscriptionLanguage(rawValue: String(code)) else {
            return .en
        }
        return lang
    }
}

// MARK: - Transcription mode

/// When transcription runs relative to the recording.
///
/// Both modes are the same code path with the same settings — the choice is
/// only how much of the work is already done by the time the user stops
/// talking. The transcript is identical either way, which is what
/// `Tests/MurmurTests` pins down.
enum TranscriptionMode: String, CaseIterable, Sendable, Identifiable {
    /// Transcribe as much of the take as the engine can while it is still
    /// being recorded.
    case live
    /// Transcribe nothing until the recording is over, then do it in one pass.
    case afterRecording

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .live:
            return t("While speaking  ·  experimental", ru: "Во время речи  ·  экспериментально")
        case .afterRecording:
            return t("After recording", ru: "После записи")
        }
    }

    /// Unknown / missing stored value falls back to live.
    static func resolve(_ raw: String?) -> TranscriptionMode {
        guard let raw, let mode = TranscriptionMode(rawValue: raw) else { return .live }
        return mode
    }
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
    /// **Default for new installs.** Language is explicit (whisper.cpp 1.8.4
    /// detect_language bug) — picked in the Language menu, defaults to locale.
    case whisperTurbo = "turbo"
    /// whisper-large-v3 via whisper.cpp + Metal — full large model, ~3 GB,
    /// Same explicit-language behavior. Slower than turbo, higher accuracy ceiling.
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
            return t("whisper-large-v3-turbo  ·  1.5 GB  ·  multilingual  ·  recommended",
                  ru: "whisper-large-v3-turbo  ·  1,5 ГБ  ·  многоязычная  ·  рекомендуется")
        case .whisperLarge:
            return t("whisper-large-v3  ·  3.0 GB  ·  multilingual",
                  ru: "whisper-large-v3  ·  3,0 ГБ  ·  многоязычная")
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
