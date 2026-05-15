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
    @Published var activeModel: SpeechModelOption = .whisperTurbo
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
            if let text = await engine?.transcribe(audio: audio), !text.isEmpty {
                mlog("Result: \(text.prefix(100))")
                waveform.hide()
                TextPaster.paste(text)
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
}
