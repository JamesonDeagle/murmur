import Foundation
import AppKit
import AVFoundation
import Carbon
import os.log

private let logFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".murmur-debug.log")

func mlog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let fh = try? FileHandle(forWritingTo: logFile) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

private nonisolated func checkAccessibility() -> Bool {
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

enum RecordingState {
    case idle
    case loading
    case recording
    case transcribing
    case paused          // model intentionally unloaded — free RAM and GPU memory
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var state: RecordingState = .loading
    /// Default for fresh installs is Parakeet — runs on Apple Neural Engine,
    /// multilingual with auto-detection, ~25× lighter than whisper. Existing
    /// users keep whatever they picked previously via UserDefaults restore in init().
    @Published var activeModel: SpeechModelOption = .parakeetV3
    @Published var selectedInputDeviceUID: String = ""
    /// Set while a model file is being downloaded / compiled, nil once
    /// the model is loaded and ready to transcribe.
    @Published var downloadProgress: DownloadProgress?

    /// Current speech engine. Swapped out when the user switches between a
    /// whisper variant and Parakeet — both wrap heavy native resources
    /// (Metal context vs. ANE-resident Core ML models) and can't coexist
    /// usefully in this menubar app's memory budget.
    var engine: (any SpeechEngine)?
    /// Tracks which backend the current `engine` is so we know when to
    /// rebuild on switch.
    private var currentEngineKind: EngineKind?

    let recorder = AudioRecorder()
    let waveform = WaveformPanel()
    private var recordingStartTime: Date?
    private let minRecordingSec: TimeInterval = 1.0
    var setupStarted = false

    init() {
        mlog("AppState init")
        // Restore last-used model. Old builds (≤ v3.3) stored "turbo" / "large"
        // — same raw values as the new SpeechModelOption enum, so they migrate
        // for free. Anything we don't recognize falls back to turbo.
        if let saved = UserDefaults.standard.string(forKey: "activeModel"),
           let restored = SpeechModelOption(rawValue: saved) {
            activeModel = restored
        }
        mlog("Active model: \(activeModel.rawValue)")

        // Restore saved device or default to built-in mic
        if let saved = UserDefaults.standard.string(forKey: "inputDeviceUID"), !saved.isEmpty {
            selectedInputDeviceUID = saved
        } else if let builtIn = InputDeviceManager.builtInMicrophone() {
            selectedInputDeviceUID = builtIn.uid
        }
        mlog("Input device UID: \(selectedInputDeviceUID)")
    }

    /// Ensure `engine` matches the requested backend; swap actors if not.
    /// Old engine's `cleanup()` is awaited so we don't leak its model into
    /// memory next to the new one.
    private func prepareEngine(for kind: EngineKind) async {
        if currentEngineKind == kind, engine != nil { return }
        if let old = engine {
            await old.cleanup()
        }
        engine = kind.makeEngine()
        currentEngineKind = kind
        mlog("prepareEngine: now using \(kind)")
    }

    private func progressForwarder() -> @Sendable (DownloadProgress) -> Void {
        return { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }
    }

    // MARK: - Stale-model cleanup

    /// How long an unused on-disk model survives before being auto-deleted.
    /// User request: "if I haven't used a model in 3 days, delete it".
    /// Storage cost of speech models is significant (whisper-large is ~3 GB,
    /// Voxtral ~2 GB, Qwen3 ~3.4 GB) and most users only use one or two
    /// actively. Auto-purge keeps disk usage in check; if the user picks a
    /// purged model later, it just re-downloads via the normal load path.
    private static let modelCacheTTL: TimeInterval = 3 * 24 * 60 * 60

    private static let lastUsedDefaultsKey = "modelLastUsed"   // [String: Date] JSON
    private static let amnestyDefaultsKey = "modelCacheAmnestyAt"  // Date

    /// Record "I used model X just now". Called from `toggle()` after a
    /// successful transcribe, so the timestamp reflects real dictation
    /// activity, not just loading the model.
    func touchLastUsed(_ option: SpeechModelOption) {
        var dict = (UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: Date]) ?? [:]
        // UserDefaults can hand back NSDate / Double depending on how it was
        // stored; coerce defensively when re-reading below.
        dict[option.rawValue] = Date()
        UserDefaults.standard.set(dict, forKey: Self.lastUsedDefaultsKey)
    }

    private func lastUsedDate(for option: SpeechModelOption) -> Date? {
        let dict = UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) ?? [:]
        if let d = dict[option.rawValue] as? Date { return d }
        if let ts = dict[option.rawValue] as? Double {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }

    /// Scan every model option, and for each one whose cache exists on disk
    /// **and** hasn't been used inside the TTL window, delete it. First-run
    /// amnesty: on a brand-new install (or upgrade from a pre-v3.9 build
    /// without timestamps), record "now" as the floor and don't delete
    /// anything yet — gives the user 3 days to actually use models before
    /// auto-purge kicks in.
    func pruneStaleModels() async {
        let now = Date()
        let amnesty = UserDefaults.standard.object(forKey: Self.amnestyDefaultsKey) as? Date
        if amnesty == nil {
            UserDefaults.standard.set(now, forKey: Self.amnestyDefaultsKey)
            mlog("pruneStaleModels: first run, granting 3-day amnesty before any deletion")
            return
        }

        for option in SpeechModelOption.allCases {
            // Build a fresh engine instance just to query cache paths.
            // Lightweight — no model load happens here.
            let probe = option.engineKind.makeEngine()
            let paths = await probe.cachedModelPaths(name: option.engineModelName)
            await probe.cleanup()

            guard !paths.isEmpty else { continue }   // model isn't on disk

            // If we have an explicit lastUsed timestamp, use that. Otherwise
            // fall back to the amnesty start so models that existed before
            // this feature shipped get the same 3-day grace as a fresh install.
            let referenceDate = lastUsedDate(for: option) ?? amnesty!
            let ageSeconds = now.timeIntervalSince(referenceDate)
            guard ageSeconds > Self.modelCacheTTL else {
                mlog("pruneStaleModels: \(option.rawValue) age=\(Int(ageSeconds))s, within TTL")
                continue
            }

            // Stale — delete every cache path the engine reported.
            for path in paths {
                do {
                    try FileManager.default.removeItem(at: path)
                    let ageDays = Int(ageSeconds / 86_400)
                    mlog("pruneStaleModels: deleted \(option.rawValue) (\(ageDays)d unused) at \(path.path)")
                } catch {
                    mlog("pruneStaleModels: failed to delete \(path.path): \(error)")
                }
            }

            // Reset the timestamp so the next download starts a new TTL window.
            var dict = UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) ?? [:]
            dict.removeValue(forKey: option.rawValue)
            UserDefaults.standard.set(dict, forKey: Self.lastUsedDefaultsKey)
        }
    }

    func selectInputDevice(_ device: AudioInputDevice) {
        selectedInputDeviceUID = device.uid
        UserDefaults.standard.set(device.uid, forKey: "inputDeviceUID")
        mlog("Input device changed to: \(device.name) (\(device.uid))")
    }

    /// Switch active model. Handles both same-engine variant changes
    /// (turbo↔large within WhisperEngine) and cross-engine switches
    /// (whisper↔parakeet), the latter destroys the old engine actor.
    /// Holds `state = .loading` for the full duration so:
    ///   - Option+Space is ignored (`case .loading` in toggle()).
    ///   - Menu items disabled-on-non-idle stay disabled.
    ///   - Menu shows progress lines instead of the idle hint.
    func switchModel(to option: SpeechModelOption) async {
        // Allow re-load if user picks the active model while paused — that's
        // effectively a resume. Plain idle + same option is a no-op.
        if activeModel == option && state == .idle && engine != nil {
            return
        }
        mlog("switchModel: \(activeModel.rawValue) -> \(option.rawValue)")
        activeModel = option
        UserDefaults.standard.set(option.rawValue, forKey: "activeModel")
        state = .loading
        downloadProgress = nil

        await prepareEngine(for: option.engineKind)
        await engine?.loadModel(name: option.engineModelName, onProgress: progressForwarder())

        downloadProgress = nil
        state = .idle
        mlog("switchModel: done, ready")
    }

    /// Free the active model context so the ~600 MB–3 GB stops sitting in
    /// CPU RAM and ANE/GPU buffers. Hotkey is still registered — pressing
    /// Option+Space in `.paused` is a no-op (see `toggle()`); user must
    /// explicitly tap Resume in the menu.
    func pauseModel() async {
        guard state == .idle else { return }
        mlog("pauseModel: unloading \(activeModel.rawValue)")
        state = .paused
        downloadProgress = nil
        await engine?.cleanup()
        mlog("pauseModel: done — model unloaded")
    }

    /// Reload the active model after pause. Reuses the same load path so
    /// the user sees the same progress UI.
    func resumeModel() async {
        guard state == .paused else { return }
        mlog("resumeModel: reloading \(activeModel.rawValue)")
        state = .loading
        downloadProgress = nil
        await prepareEngine(for: activeModel.engineKind)
        await engine?.loadModel(name: activeModel.engineModelName, onProgress: progressForwarder())
        downloadProgress = nil
        state = .idle
        mlog("resumeModel: done, ready")
    }

    func startSetup() {
        guard !setupStarted else { return }
        setupStarted = true
        mlog("startSetup called")
        Task { @MainActor in
            await self.setup()
        }
    }

    func setup() async {
        // Check mic permission
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        mlog("Mic permission status: \(micStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            mlog("Mic permission requested, granted=\(granted)")
        } else if micStatus != .authorized {
            mlog("WARNING: Mic permission NOT authorized!")
        }

        // Check Accessibility permission (required for Cmd+V paste simulation)
        let axTrusted = checkAccessibility()
        mlog("Accessibility permission: \(axTrusted)")
        if !axTrusted {
            mlog("WARNING: Accessibility NOT granted — text paste will not work")
        }

        // Register global hotkey: Option+Space
        HotkeyManager.shared.register(
            modifiers: UInt32(optionKey),
            keyCode: 49 // Space
        ) { [weak self] in
            Task { @MainActor in
                await self?.toggle()
            }
        }

        // Register Escape to cancel
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    self?.cancel()
                }
                return nil
            }
            return event
        }

        // Stale-model cleanup runs before we load anything — if the active
        // model itself is past TTL, it gets deleted here and re-downloaded
        // below via the normal progress UI.
        await pruneStaleModels()

        mlog("Loading model: \(activeModel.rawValue)")
        await prepareEngine(for: activeModel.engineKind)
        await engine?.loadModel(name: activeModel.engineModelName, onProgress: progressForwarder())
        downloadProgress = nil
        mlog("Model loaded, ready")
        state = .idle
    }

    func toggle() async {
        let currentState = "\(self.state)"
        mlog("Toggle called, state: \(currentState)")
        switch state {
        case .idle:
            state = .recording
            recordingStartTime = Date()
            waveform.show()

            // Resolve input device: saved → built-in → system default
            let deviceID: AudioDeviceID? = {
                if !selectedInputDeviceUID.isEmpty,
                   let dev = InputDeviceManager.device(forUID: selectedInputDeviceUID) {
                    return dev.id
                }
                if let builtIn = InputDeviceManager.builtInMicrophone() {
                    return builtIn.id
                }
                return nil // system default
            }()

            recorder.start(deviceID: deviceID) { [weak self] levels in
                Task { @MainActor in
                    self?.waveform.updateLevels(levels)
                }
            }

        case .recording:
            // Accidental press protection
            if let start = recordingStartTime,
               Date().timeIntervalSince(start) < minRecordingSec {
                mlog("Too short, cancelling")
                cancel()
                return
            }

            state = .transcribing
            let audio = recorder.stop()
            mlog("Audio captured: \(audio.count) samples (\(Double(audio.count) / 16000.0)s)")
            waveform.setTranscribing()

            if audio.isEmpty {
                mlog("Empty audio, skipping transcription")
                waveform.hide()
                state = .idle
                return
            }

            mlog("Transcribing...")
            if let rawText = await engine?.transcribe(audio: audio), !rawText.isEmpty {
                let text = Self.sanitizeTranscript(rawText)
                mlog("Result: \(text.prefix(100))")
                waveform.hide()
                TextPaster.paste(text)
                // Mark the active model as "used today" so it survives the
                // next stale-model sweep on startup.
                touchLastUsed(activeModel)
            } else {
                mlog("No text returned")
                waveform.hide()
            }
            state = .idle

        case .loading:
            // Model still loading, ignore
            break

        case .transcribing:
            // Already transcribing, ignore
            break

        case .paused:
            // Model intentionally unloaded. Don't auto-resume on hotkey —
            // resume + record + transcribe would block the hotkey for
            // 10+ seconds while whisper_init runs, which feels broken.
            // User taps Resume in the menu first.
            mlog("Toggle ignored: model paused. Tap Resume in menu first.")
            break
        }
    }

    func cancel() {
        guard state == .recording else { return }
        recorder.stop()
        waveform.hide()
        state = .idle
    }

    // MARK: - Transcript sanitization

    /// Clean up tokenizer artifacts before pasting.
    ///
    /// Parakeet TDT's SentencePiece vocabulary is optimized for size and
    /// doesn't include certain typographic punctuation (e.g. Russian
    /// guillemets « », curly quotes “ ”, em-dashes). When the acoustic
    /// model "hears" a quote-like intonation but can't find a matching
    /// token, it falls back to the unknown-token sentinel `<unk>`,
    /// producing output like:
    ///
    ///     ...кнопка <unk>Написать в техподдержку<unk>. Но...
    ///
    /// Whisper-family models (whisper.cpp, WhisperKit) don't have this
    /// problem — their BPE tokenizer covers full Unicode. The sanitizer
    /// is engine-agnostic but in practice only matters for Parakeet.
    ///
    /// Strategy:
    ///   - Paired `<unk>...<unk>` (very short payload, typical quotation
    ///     pattern) → replace both with straight double quotes `"`.
    ///   - Any remaining stray `<unk>` → drop. We can't recover what the
    ///     model meant, and a missing word reads better than a literal
    ///     `<unk>` in pasted text.
    ///   - Also strip a few other SentencePiece special tokens just in
    ///     case (`<pad>`, `<s>`, `</s>`, `<bos>`, `<eos>`).
    ///   - Collapse the double spaces that fall out of the cleanup.
    static func sanitizeTranscript(_ text: String) -> String {
        var s = text

        // Paired <unk>...<unk> within a short window → double quotes.
        // Keeps `<unk>Написать в техподдержку<unk>` → `"Написать в техподдержку"`
        // but won't merge two unrelated quoted phrases on the same line.
        if let regex = try? NSRegularExpression(
            pattern: "<unk>([^<]{1,120}?)<unk>",
            options: []
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(
                in: s,
                options: [],
                range: range,
                withTemplate: "\"$1\""
            )
        }

        // Strip any leftover specials.
        for token in ["<unk>", "<pad>", "<s>", "</s>", "<bos>", "<eos>"] {
            s = s.replacingOccurrences(of: token, with: "")
        }

        // Cleanup whitespace artifacts left by deletions.
        if let ws = try? NSRegularExpression(pattern: "[ \\t]{2,}", options: []) {
            s = ws.stringByReplacingMatches(
                in: s,
                options: [],
                range: NSRange(s.startIndex..., in: s),
                withTemplate: " "
            )
        }
        // Space-before-punctuation that can appear after `<unk>` removal.
        if let sp = try? NSRegularExpression(pattern: " ([,.;:!?])", options: []) {
            s = sp.stringByReplacingMatches(
                in: s,
                options: [],
                range: NSRange(s.startIndex..., in: s),
                withTemplate: "$1"
            )
        }

        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned != text {
            mlog("sanitizeTranscript: cleaned tokenizer artifacts (\(text.count) → \(cleaned.count) chars)")
        }
        return cleaned
    }
}
