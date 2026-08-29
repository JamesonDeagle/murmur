import Foundation
import Accelerate
import CWhisper

/// Budget for `encoderGate` — see `WhisperEngine.decodeWindow`.
private final class WindowGate: @unchecked Sendable {
    var budget = 0
}

/// Stops `whisper_full` after a fixed number of encoder passes.
///
/// whisper_full does not decode "one window and return": it loops, encoding a
/// fresh 30 s window from wherever the previous one left off, until it runs
/// out of audio. Mid-recording that means it would encode windows reaching
/// past what has actually been recorded — into silence that will not be
/// silent by the time the user stops. Returning false here aborts the loop
/// and keeps the segments already produced.
///
/// `duration_ms` cannot do this job: it also moves `seek_end`, and the
/// decoder consults `seek_end` to decide whether a segment that ran into the
/// edge of the audio should be accepted or retried. Shrinking it makes every
/// window behave like the last one of a take.
private let encoderGate: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Bool = { _, _, user in
    guard let user else { return true }
    let gate = Unmanaged<WindowGate>.fromOpaque(user).takeUnretainedValue()
    guard gate.budget > 0 else { return false }
    gate.budget -= 1
    return true
}

/// whisper.cpp-backed speech engine. Handles both turbo and large variants
/// — the variant is chosen via the `name` parameter to `loadModel`.
///
/// Transcription is a **session**: audio is appended while the user talks and
/// every whisper window that becomes complete is decoded right away, so when
/// the user stops only the unfinished tail is left. The output is the same
/// text a single post-hoc `whisper_full` over the identical buffer produces —
/// see the session block below for the three properties that guarantee it.
actor WhisperEngine: SpeechEngine {
    private var ctx: OpaquePointer?
    private let modelsDir: URL

    /// Transcription language. whisper.cpp 1.8.4 can't auto-detect (the
    /// detect_language path yields 0 segments), so an explicit code is always
    /// set — AppState pushes the user's pick here after loadModel and on
    /// every change in the Language menu.
    private var language: TranscriptionLanguage = .systemDefault

    private let models: [String: String] = [
        "turbo": "ggml-large-v3-turbo.bin",
        "large": "ggml-large-v3.bin",
    ]

    // MARK: - Session state

    private static let sampleRate = Int(WHISPER_SAMPLE_RATE)
    /// whisper's encoder window: a compile-time constant of the model
    /// (WHISPER_CHUNK_SIZE), not a value we get to choose.
    private static let windowSamples = 30 * sampleRate
    /// Extra audio required past the window before decoding it. Keeps the
    /// window clear of the recorded edge, so the decoder never sees the end
    /// of the buffer as the end of the take.
    private static let marginSamples = 2 * sampleRate

    /// The whole take, 16 kHz mono, append-only. Every window is decoded from
    /// this one buffer via `offset_ms`; nothing is ever sliced out of it and
    /// nothing already written is rewritten. That is what makes a window
    /// decoded mid-recording identical to the same window decoded afterwards.
    private var buffer: [Float] = []
    /// Where the next window starts, in centiseconds — whisper's own unit.
    /// It reports this itself as the end timestamp of the last segment it
    /// decoded, which is exactly how it advances the seek inside one call.
    private var seekCentis = 0
    private var transcript = ""
    /// nil until the take's gain has been decided — see `fixGain`.
    private var gain: Float?
    private var sessionCancelled = false
    private var mode: TranscriptionMode = .live
    private let gate = WindowGate()

    func setLanguage(_ code: String) async {
        language = TranscriptionLanguage.resolve(code)
        mlog("WhisperEngine: language set to \(language.rawValue)")
    }

    /// `.afterRecording` simply never lets a window fire, so `endSession`
    /// finds the seek still at zero and decodes the whole take in one pass from
    /// offset zero — the pre-window behaviour, not a second implementation
    /// of it.
    func setMode(_ mode: TranscriptionMode) async {
        self.mode = mode
        mlog("WhisperEngine: mode = \(mode.rawValue)")
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDir = appSupport.appendingPathComponent("Murmur/models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    // MARK: - Model lifecycle

    func loadModel(
        name: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async {
        mlog("WhisperEngine.loadModel: \(name)")

        // CRITICAL: nil out BEFORE free so any concurrent call suspended on
        // this actor's queue sees nil instead of a dangling pointer. Without
        // this, switching models (especially while a slow download is in
        // flight on `await downloadModel`) caused EXC_BAD_ACCESS in
        // whisper_full when Option+Space was pressed mid-switch.
        if let oldCtx = ctx {
            ctx = nil
            whisper_free(oldCtx)
        }
        resetSession()

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

        if ctx != nil {
            let silence = [Float](repeating: 0, count: Self.sampleRate)
            buffer = silence
            _ = decode(gated: false)
            resetSession()
            print("Whisper model '\(name)' loaded and warmed up")
        }
    }

    func cleanup() async {
        if let ctx = ctx {
            whisper_free(ctx)
            self.ctx = nil
        }
        resetSession()
    }

    // MARK: - Session
    //
    // Feeding whisper window by window reproduces a single whisper_full call
    // byte for byte as long as three things hold, and every one of them is a
    // detail of how whisper_full works internally rather than a heuristic:
    //
    //   1. Windows read real audio. A window is only decoded once the buffer
    //      holds all 30 s of it plus a margin, so it never encodes samples
    //      that haven't been recorded yet.
    //   2. The buffer is passed whole, with `offset_ms` selecting the window.
    //      Mel frames then match the ones a post-hoc pass would compute.
    //   3. The decoder context is chained. Inside one whisper_full call each
    //      window is decoded with the previous window's text as its prompt;
    //      `no_context` breaks the chain to the previous CALL, not between
    //      windows. Our windows are separate calls, so only the first one
    //      sets it — after that the chain continues on its own through
    //      whisper_state, exactly as it would inside a single call.

    func beginSession() {
        resetSession()
    }

    /// Appends freshly captured audio and decodes every window it completed.
    /// This is the work that would otherwise all land after the user stops.
    func append(_ samples: [Float]) {
        guard ctx != nil, !sessionCancelled, !samples.isEmpty else { return }

        if let gain, gain != 1 {
            var scaled = samples
            var g = gain
            vDSP_vsmul(scaled, 1, &g, &scaled, 1, vDSP_Length(scaled.count))
            buffer.append(contentsOf: scaled)
        } else {
            buffer.append(contentsOf: samples)
        }

        while mode == .live, buffer.count >= seekSamples + Self.windowSamples + Self.marginSamples {
            fixGain()
            guard decode(gated: true) else { break }
        }
    }

    /// No more audio: decode whatever is left and return the whole transcript.
    func endSession() -> String? {
        defer { resetSession() }
        guard ctx != nil, !sessionCancelled, !buffer.isEmpty else { return nil }

        fixGain()
        let tailSec = Double(buffer.count - seekSamples) / Double(Self.sampleRate)
        mlog("WhisperEngine.endSession: decoded up to \(seekCentis) cs, tail \(String(format: "%.1f", tailSec))s")
        _ = decode(gated: false)

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// User cancelled — drop the take without decoding the tail.
    func abortSession() {
        resetSession()
        sessionCancelled = true
    }

    private var seekSamples: Int { seekCentis * (Self.sampleRate / 100) }

    /// Nothing of this take has been handed to whisper yet. Drives the two
    /// parameters that only apply to a take's opening window.
    private var isFirstDecode: Bool { seekCentis == 0 }

    private func resetSession() {
        buffer = []
        seekCentis = 0
        transcript = ""
        gain = nil
        sessionCancelled = false
    }

    /// Peak-normalizes the take once and then leaves it alone.
    ///
    /// The old code normalized the finished recording against its global peak.
    /// A growing buffer has no global peak to know, and rescaling audio that
    /// whisper has already read would break the append-only guarantee the
    /// session depends on. So the gain is decided the first time it is needed
    /// — before any window is decoded — and frozen. For a take shorter than
    /// one window that first moment is the end of the recording, which is the
    /// old behaviour exactly.
    private func fixGain() {
        guard gain == nil else { return }
        gain = 1
        guard !buffer.isEmpty else { return }

        var peak: Float = 0
        vDSP_maxmgv(buffer, 1, &peak, vDSP_Length(buffer.count))
        guard peak > 0.001 else { return }

        let candidate = min(0.9 / peak, 50.0) // Cap gain at 50x to avoid amplifying pure noise
        guard candidate > 1.5 else { return }

        gain = candidate
        var g = candidate
        vDSP_vsmul(buffer, 1, &g, &buffer, 1, vDSP_Length(buffer.count))
        mlog("WhisperEngine: gain fixed at \(String(format: "%.1f", candidate))x (peak \(String(format: "%.3f", peak)))")
    }

    /// Decodes from `seekCentis`. Gated runs stop after one window; the final
    /// run decodes everything left. Returns false when nothing came back and
    /// windowing should stop.
    private func decode(gated: Bool) -> Bool {
        guard let ctx else { return false }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = true
        params.suppress_blank = false
        params.offset_ms = Int32(seekCentis * 10)
        params.duration_ms = 0          // never bound it — see `encoderGate`
        params.no_context = isFirstDecode

        // Bug in whisper.cpp 1.8.4: detect_language=true + language="auto"
        // produces 0 segments. Use the explicit user-picked language instead
        // (Language menu, defaults to the system locale).
        let langStr = strdup(language.rawValue)
        params.language = UnsafePointer(langStr)
        params.detect_language = false

        // Style prompt goes in once per take. A single whisper_full call also
        // applies it once (carry_initial_prompt is off), and from the second
        // window on the decoder is conditioned on the real transcript anyway.
        let promptStr = isFirstDecode ? strdup(language.initialPrompt) : nil
        params.initial_prompt = promptStr.map { UnsafePointer($0) }

        if gated {
            gate.budget = 1
            params.encoder_begin_callback = encoderGate
            params.encoder_begin_callback_user_data = Unmanaged.passUnretained(gate).toOpaque()
        }

        let started = Date()
        let result = buffer.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        free(langStr)
        if let promptStr { free(promptStr) }

        guard result == 0 else {
            mlog("WhisperEngine: whisper_full failed (\(result))")
            return false
        }

        let n = whisper_full_n_segments(ctx)
        guard n > 0 else { return false }
        for i in 0..<n {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                transcript += String(cString: cStr)
            }
        }

        // whisper reports where it stopped; that timestamp is the next window's
        // start, the same way it advances its own seek inside a single call.
        let end = Int(whisper_full_get_segment_t1(ctx, n - 1))
        let elapsed = Date().timeIntervalSince(started)
        mlog("WhisperEngine: \(gated ? "window" : "final") \(seekCentis)→\(end) cs, \(n) seg, \(String(format: "%.2f", elapsed))s")

        guard end > seekCentis else { return false }
        seekCentis = end
        return true
    }

    // MARK: - Model download

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

    func cachedModelPaths(name: String) async -> [URL] {
        guard let filename = models[name] else { return [] }
        let path = modelsDir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: path.path) ? [path] : []
    }
}
