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
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var state: RecordingState = .loading
    @Published var activeModel: String = "turbo"
    @Published var selectedInputDeviceUID: String = ""
    /// Set while a model file is being downloaded from HuggingFace, nil once
    /// the file is on disk and we're just initializing the whisper context.
    @Published var downloadProgress: DownloadProgress?

    let engine = TranscriptionEngine()
    let recorder = AudioRecorder()
    let waveform = WaveformPanel()
    private var recordingStartTime: Date?
    private let minRecordingSec: TimeInterval = 1.0
    var setupStarted = false

    init() {
        mlog("AppState init")
        // Restore last-used model (whitelist against known names so an old/typo
        // value in UserDefaults can't crash loadModel)
        if let saved = UserDefaults.standard.string(forKey: "activeModel"),
           ["turbo", "large"].contains(saved) {
            activeModel = saved
        }
        mlog("Active model: \(activeModel)")

        // Restore saved device or default to built-in mic
        if let saved = UserDefaults.standard.string(forKey: "inputDeviceUID"), !saved.isEmpty {
            selectedInputDeviceUID = saved
        } else if let builtIn = InputDeviceManager.builtInMicrophone() {
            selectedInputDeviceUID = builtIn.uid
        }
        mlog("Input device UID: \(selectedInputDeviceUID)")
    }

    func selectInputDevice(_ device: AudioInputDevice) {
        selectedInputDeviceUID = device.uid
        UserDefaults.standard.set(device.uid, forKey: "inputDeviceUID")
        mlog("Input device changed to: \(device.name) (\(device.uid))")
    }

    /// Switch active whisper model. Holds `state = .loading` for the full
    /// duration of download + init so that:
    ///   - Option+Space is ignored (`case .loading` falls through in toggle()).
    ///   - Menu items disabled-on-non-idle stay disabled.
    ///   - Menu shows "Loading model..." instead of the idle hint.
    /// Without this, a 3GB download could leave the UI in `.idle` while the
    /// engine was mid-swap, allowing a use-after-free crash.
    func switchModel(to name: String) async {
        guard activeModel != name || state == .loading else {
            // Already on this model and not currently loading — no-op.
            return
        }
        mlog("switchModel: \(activeModel) -> \(name)")
        activeModel = name
        UserDefaults.standard.set(name, forKey: "activeModel")
        state = .loading
        downloadProgress = nil

        // Download progress arrives from a URLSession delegate queue —
        // hop to MainActor before touching @Published.
        await engine.loadModel(name: name) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        downloadProgress = nil
        state = .idle
        mlog("switchModel: done, ready")
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

        mlog("Loading model...")
        await engine.loadModel(name: activeModel) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }
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
            if let text = await engine.transcribe(audio: audio), !text.isEmpty {
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
        }
    }

    func cancel() {
        guard state == .recording else { return }
        recorder.stop()
        waveform.hide()
        state = .idle
    }
}
