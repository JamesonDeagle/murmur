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

enum RecordingState {
    case idle
    case loading
    case recording
    case transcribing
    case paused          // model intentionally unloaded — free RAM and GPU memory
}

/// User-selectable global hotkey presets.
///
/// Option+Space is the historical Murmur default and works on this macOS 26
/// machine. Some macOS 15.x builds reject `RegisterEventHotKey` for combos
/// whose only modifiers are Option and/or Shift (error -9868, FB15168205) —
/// `AppState.registerHotkey` checks the registration result and silently
/// falls back to Cmd+Shift+Space on such systems. We deliberately avoid
/// Control+Option+Space — that's the system input-source switcher.
enum HotkeyCombo: String, CaseIterable, Sendable, Identifiable {
    case optionSpace     // ⌥Space — default (auto-fallback to ⌘⇧Space if OS refuses)
    case cmdShiftSpace   // ⌘⇧Space
    case ctrlShiftSpace  // ⌃⇧Space
    case cmdShiftD       // ⌘⇧D

    var id: String { rawValue }

    /// Carbon modifier mask, virtual key code, and the label shown in the UI.
    var resolved: (modifiers: UInt32, keyCode: UInt32, label: String) {
        switch self {
        case .optionSpace:
            return (UInt32(optionKey), 49, "⌥Space")
        case .cmdShiftSpace:
            return (UInt32(cmdKey | shiftKey), 49, "⌘⇧Space")
        case .ctrlShiftSpace:
            return (UInt32(controlKey | shiftKey), 49, "⌃⇧Space")
        case .cmdShiftD:
            return (UInt32(cmdKey | shiftKey), 2, "⌘⇧D")  // keyCode 2 = D
        }
    }

    /// Map a stored UserDefaults raw value back to a preset, defaulting to
    /// `.optionSpace` for anything unrecognized (forward-compat / corruption).
    static func resolve(_ raw: String?) -> HotkeyCombo {
        guard let raw, let combo = HotkeyCombo(rawValue: raw) else { return .optionSpace }
        return combo
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var state: RecordingState = .loading
    /// Default for fresh installs is whisper-turbo — after A/B testing all
    /// engines on real Russian dictation, whisper-large-v3-turbo via
    /// whisper.cpp + Metal gave the best transcription quality.
    /// Existing users keep whatever they picked previously via the
    /// UserDefaults restore in init().
    @Published var activeModel: SpeechModelOption = .whisperTurbo
    @Published var selectedInputDeviceUID: String = ""
    /// Set while a model file is being downloaded / compiled, nil once
    /// the model is loaded and ready to transcribe.
    @Published var downloadProgress: DownloadProgress?

    /// Active global hotkey preset. Restored from UserDefaults in init();
    /// changing it via `setHotkeyCombo` persists + re-registers the hotkey.
    @Published var hotkeyCombo: HotkeyCombo = .cmdShiftSpace

    /// Transcription language (whisper needs it explicit — auto-detect is
    /// broken in whisper.cpp 1.8.4). Defaults to the system locale when
    /// supported, English otherwise; persisted across launches.
    @Published var transcriptionLanguage: TranscriptionLanguage = .systemDefault

    /// Whether macOS lets us synthesize Cmd+V (the post-events /
    /// Accessibility permission). When false, dictation still "works" —
    /// the text lands on the clipboard — but auto-paste AND the global
    /// Escape monitor are both dead, and both fail silently at the OS
    /// level. The menu shows a warning driven by this flag.
    ///
    /// CRITICAL (bug fix): macOS applies PostEvent/Accessibility access
    /// **only at process launch**. `CGPreflightPostEventAccess()` keeps
    /// returning false in a running process even after the user ticks the
    /// box in System Settings — the grant is picked up only on the next
    /// launch. So re-checking this flag at toggle/paste can reliably
    /// detect permission *loss* (e.g. a new build's cdhash invalidated the
    /// grant) but NOT a fresh *grant*. The earlier "clears without restart"
    /// promise was wrong; the warning now tells the user to restart and
    /// offers a one-click relaunch (`relaunch()`).
    @Published var canPostEvents: Bool = true

    /// Human-readable label for the active hotkey ("⌘⇧Space"), for the menu.
    var hotkeyLabel: String { hotkeyCombo.resolved.label }

    /// Current speech engine. Only whisper.cpp ships today; the engine is held
    /// behind `any SpeechEngine` + `EngineKind` so re-introducing extra
    /// backends later (Parakeet, MLX) stays an additive change.
    var engine: (any SpeechEngine)?
    /// Tracks which backend the current `engine` is so we know when to
    /// rebuild on switch.
    private var currentEngineKind: EngineKind?

    let recorder = AudioRecorder()
    let waveform = WaveformPanel()

    /// Live transcription pipeline. The recorder pushes 16 kHz blocks into
    /// `audioFeed`; `transcription` drains them into the engine's session in
    /// order and, once the feed closes, returns the finished transcript.
    private var audioFeed: AsyncStream<[Float]>.Continuation?
    private var transcription: Task<String?, Never>?
    private var recordingStartTime: Date?
    private let minRecordingSec: TimeInterval = 1.0
    var setupStarted = false

    init() {
        mlog("AppState init")
        // Restore last-used model. "turbo" / "large" migrate for free (same
        // raw values). Anything we don't recognize falls back to turbo —
        // including users who previously picked one of the now-removed engines
        // ("parakeet" / "voxtral" / "qwen3"): SpeechModelOption(rawValue:)
        // returns nil for those and we keep the default. That's the intended
        // behavior for this whisper-only build.
        if let saved = UserDefaults.standard.string(forKey: "activeModel"),
           let restored = SpeechModelOption(rawValue: saved) {
            activeModel = restored
        }
        mlog("Active model: \(activeModel.rawValue)")

        // Restore saved hotkey preset. Unknown / missing → ⌘⇧Space default.
        hotkeyCombo = HotkeyCombo.resolve(UserDefaults.standard.string(forKey: "hotkeyCombo"))
        mlog("Hotkey combo: \(hotkeyCombo.rawValue) (\(hotkeyCombo.resolved.label))")

        // Restore transcription language. Missing/unknown → system locale → en.
        transcriptionLanguage = TranscriptionLanguage.resolve(UserDefaults.standard.string(forKey: "language"))
        mlog("Transcription language: \(transcriptionLanguage.rawValue)")

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
        await engine?.setLanguage(transcriptionLanguage.rawValue)
        mlog("prepareEngine: now using \(kind), language \(transcriptionLanguage.rawValue)")
    }

    /// Change the transcription language: persist and push into the live
    /// engine so the very next dictation uses it. Callable from the menu.
    func setTranscriptionLanguage(_ lang: TranscriptionLanguage) {
        guard lang != transcriptionLanguage else { return }
        mlog("setTranscriptionLanguage: \(transcriptionLanguage.rawValue) -> \(lang.rawValue)")
        transcriptionLanguage = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "language")
        Task { [weak self] in
            await self?.engine?.setLanguage(lang.rawValue)
        }
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
    /// turbo ~1.5 GB) and most users only use one actively. Auto-purge keeps
    /// disk usage in check; if the user picks a purged model later, it just
    /// re-downloads via the normal load path.
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

    /// Switch active model. Today both options live in the same WhisperEngine
    /// actor (turbo↔large), so `prepareEngine` keeps the actor and only the
    /// `.bin` reloads. The cross-engine swap path is retained for when extra
    /// backends return. Holds `state = .loading` for the full duration so:
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

    // MARK: - Hotkey

    /// Change the active global hotkey: persist the choice and re-register so
    /// it takes effect immediately. Callable from the menu's Shortcut submenu.
    func setHotkeyCombo(_ combo: HotkeyCombo) {
        guard combo != hotkeyCombo else { return }
        mlog("setHotkeyCombo: \(hotkeyCombo.rawValue) -> \(combo.rawValue)")
        hotkeyCombo = combo
        UserDefaults.standard.set(combo.rawValue, forKey: "hotkeyCombo")
        registerHotkey()
    }

    /// (Re)register the global hotkey from the current `hotkeyCombo`.
    private func registerHotkey() {
        let r = hotkeyCombo.resolved
        let onToggle: () -> Void = { [weak self] in
            Task { @MainActor in
                await self?.toggle()
            }
        }
        if HotkeyManager.shared.register(modifiers: r.modifiers, keyCode: r.keyCode, onToggle: onToggle) {
            mlog("registerHotkey: \(r.label)")
            return
        }
        // The OS refused the combo (some macOS 15.x builds reject Option/
        // Shift-only hotkeys, FB15168205). Fall back to Cmd+Shift+Space so
        // dictation keeps working; reflect the change in the menu but do NOT
        // persist it — on an OS where the user's preferred combo works again,
        // it comes back automatically.
        let fallback = HotkeyCombo.cmdShiftSpace
        let f = fallback.resolved
        if hotkeyCombo != fallback,
           HotkeyManager.shared.register(modifiers: f.modifiers, keyCode: f.keyCode, onToggle: onToggle) {
            mlog("registerHotkey: OS refused \(r.label), fell back to \(f.label)")
            hotkeyCombo = fallback
        } else {
            mlog("registerHotkey: FAILED for \(r.label) and fallback — global hotkey inactive")
        }
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

        // Check "post events" permission (required for Cmd+V paste simulation).
        // Under App Sandbox this is the sandbox-compatible alternative to full
        // Accessibility (which the sandbox forbids). Prompts on first run.
        let postEventGranted = TextPaster.ensurePermission()
        canPostEvents = postEventGranted
        mlog("setup: PostEvent permission = \(postEventGranted)")

        // Register the global hotkey from the saved preset (default ⌘⇧Space).
        registerHotkey()

        // Escape cancels an in-progress recording. We need TWO monitors
        // because users dictate to insert text into OTHER apps — so the
        // foreground app is almost never Murmur, and a local-only monitor
        // wouldn't see the Escape key at all.
        //
        // Local monitor: fires when Murmur itself is frontmost (e.g. the
        // menubar dropdown is open). Returning nil swallows the event so
        // it doesn't propagate into our SwiftUI hierarchy.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    self?.cancel()
                }
                return nil
            }
            return event
        }
        // Global monitor: fires when any OTHER app is frontmost. AppKit
        // doesn't let global monitors swallow events (callback returns
        // Void), so Escape still reaches the foreground app — which is
        // exactly what we want, Escape there usually just closes a
        // modal / removes focus. Side-effect-free for the user.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    self?.cancel()
                }
            }
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

    /// Menu action for the missing-permission warning. Re-triggers the
    /// system prompt when possible (it only ever shows once — after a
    /// dismissed prompt macOS silently denies forever), then opens the
    /// Accessibility pane where the user flips the toggle manually. Also
    /// the place ad-hoc-signed builds usually end up: macOS sometimes
    /// never shows them the prompt at all, and the app must be added to
    /// the list by hand.
    func openPastePermissionSettings() {
        TextPaster.ensurePermission()
        canPostEvents = TextPaster.hasPermission
        mlog("openPastePermissionSettings: granted=\(canPostEvents)")
        guard !canPostEvents else { return }
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunch the app — the only way to pick up a freshly-granted
    /// PostEvent/Accessibility permission (macOS applies it at launch, see
    /// `canPostEvents`). Launches a brand-new instance and quits this one.
    ///
    /// We spawn the new instance with `createsNewApplicationInstance` so
    /// macOS doesn't just re-activate the dying process, then terminate
    /// ourselves from the completion handler so the new one is already
    /// coming up. `NSWorkspace.openApplication` is used (not a shell
    /// `open`) so this also works under App Sandbox in the MAS build.
    /// Mirrors the Quit button's teardown (unregister hotkey, free engine).
    func relaunch() {
        mlog("relaunch: launching fresh instance + terminating pid \(ProcessInfo.processInfo.processIdentifier)")
        HotkeyManager.shared.unregister()
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { mlog("relaunch: openApplication error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func toggle() async {
        let currentState = "\(self.state)"
        mlog("Toggle called, state: \(currentState)")
        // Cheap TCC preflight (no prompt) — keeps the menu warning in sync
        // if the user granted/revoked the permission since the last check.
        canPostEvents = TextPaster.hasPermission
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

            // Audio goes straight into a transcription session instead of
            // piling up until the user stops. A single consumer task keeps
            // the blocks in the order they were spoken.
            let (blocks, feed) = AsyncStream<[Float]>.makeStream()
            audioFeed = feed
            transcription = Task { [engine] in
                guard let engine else { return nil }
                await engine.beginSession()
                for await block in blocks {
                    await engine.append(block)
                }
                return await engine.endSession()
            }

            recorder.start(
                deviceID: deviceID,
                onLevels: { [weak self] levels in
                    Task { @MainActor in
                        self?.waveform.updateLevels(levels)
                    }
                },
                onAudio: { feed.yield($0) }
            )

        case .recording:
            // Accidental press protection
            if let start = recordingStartTime,
               Date().timeIntervalSince(start) < minRecordingSec {
                mlog("Too short, cancelling")
                cancel()
                return
            }

            state = .transcribing
            recorder.stop()
            waveform.setTranscribing()

            // Closing the feed is what tells the session the take is over.
            // Whatever windows already decoded while the user was talking are
            // kept; only the tail is left to process here.
            audioFeed?.finish()
            audioFeed = nil
            let rawText = await transcription?.value ?? nil
            transcription = nil

            if let rawText, !rawText.isEmpty {
                let text = Self.sanitizeTranscript(rawText)
                mlog("Result: \(text.prefix(100))")
                waveform.hide()
                TextPaster.paste(text)
                canPostEvents = TextPaster.hasPermission
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
        audioFeed?.finish()
        audioFeed = nil
        // Drop the take instead of decoding a tail nobody asked for. The
        // consumer task ends by itself once the feed is closed.
        if let engine, let task = transcription {
            Task {
                await engine.abortSession()
                _ = await task.value
            }
        }
        transcription = nil
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
