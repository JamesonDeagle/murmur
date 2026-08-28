import AVFoundation
import Accelerate
import CoreAudio
import AudioToolbox

/// Captures the microphone and emits 16 kHz mono blocks as they arrive.
///
/// It keeps nothing: no take-sized buffer, no post-processing pass. Whoever
/// consumes `onAudio` owns the recording. That's what lets transcription run
/// alongside the recording instead of after it — see `WhisperEngine`'s session.
/// Unchecked because the compiler can't see the discipline: mutable state is
/// either guarded by `lock` (the callbacks) or owned by a single queue (the
/// resampler), and `engine` is only touched from the main actor.
class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let targetSampleRate: Double = 16000
    private var levelsCallback: (([Float]) -> Void)?
    private var audioCallback: (@Sendable ([Float]) -> Void)?
    private var resampler = StreamingResampler(ratio: 1)
    private let numBars = 11
    private let barWeights: [Float] = [0.3, 0.5, 0.7, 0.85, 0.95, 1.0, 0.95, 0.85, 0.7, 0.5, 0.3]
    private let lock = NSLock()

    /// Resampling runs here rather than on the realtime audio thread. Serial,
    /// so blocks reach the consumer in the order they were spoken, and
    /// `stop()` can use it as a drain barrier.
    private let resampleQueue = DispatchQueue(label: "com.deagle.murmur.resample")

    func start(
        deviceID: AudioDeviceID? = nil,
        onLevels: @escaping ([Float]) -> Void,
        onAudio: @escaping @Sendable ([Float]) -> Void
    ) {
        lock.lock()
        levelsCallback = onLevels
        audioCallback = onAudio
        lock.unlock()

        engine = AVAudioEngine()
        guard let engine = engine else { return }

        let inputNode = engine.inputNode

        // Point THIS engine's input at the requested device, without touching
        // the system-wide default input (which would be a sandbox violation —
        // modifying a system preference is not covered by the audio-input
        // entitlement and gets the app rejected in App Review).
        //
        // CRITICAL: skip the rebind entirely when the requested device IS the
        // system default. Re-pointing the AUHAL at the device it is already
        // configured for silently broke capture on macOS 26 (engine started,
        // tap never fired, 0 samples — v3.22 field regression). Reading the
        // default input is a read-only query and sandbox-safe.
        //
        // When a rebind IS needed (user picked a non-default mic), order is
        // load-bearing: set the device on the input node's audio unit BEFORE
        // querying its output format or installing the tap. On any failure we
        // log and fall through to the system default — never crash.
        let systemDefault = Self.currentDefaultInputDevice()
        if let deviceID = deviceID, deviceID != systemDefault {
            if let au = inputNode.audioUnit {
                var dev = deviceID
                let st = AudioUnitSetProperty(
                    au,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &dev,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if st == noErr {
                    mlog("AudioRecorder: input node bound to device \(deviceID) (system default is \(systemDefault))")
                } else {
                    mlog("AudioRecorder: AudioUnitSetProperty(CurrentDevice) failed (\(st)) — using system default")
                }
            } else {
                mlog("AudioRecorder: inputNode.audioUnit is nil — using system default")
            }
        } else {
            mlog("AudioRecorder: requested device \(deviceID.map(String.init) ?? "nil") is the system default (\(systemDefault)) — no rebind needed")
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let nativeSampleRate = nativeFormat.sampleRate
        mlog("AudioRecorder: native format sr=\(nativeFormat.sampleRate) ch=\(nativeFormat.channelCount)")

        // Safe to assign unsynchronized: the previous stop() drained
        // `resampleQueue` before returning and no tap is installed yet.
        resampler = StreamingResampler(ratio: targetSampleRate / nativeSampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }
            guard let floatData = pcmBuffer.floatChannelData?[0] else { return }
            let count = Int(pcmBuffer.frameLength)

            // Copy samples immediately — buffer is reused by the engine after callback returns
            let samples = Array(UnsafeBufferPointer(start: floatData, count: count))

            // Compute RMS for visualization
            var rms: Float = 0
            vDSP_rmsqv(floatData, 1, &rms, vDSP_Length(count))
            let level = min(1.0, rms * 15.0)

            var bars = [Float](repeating: 0, count: self.numBars)
            for i in 0..<self.numBars {
                bars[i] = level * self.barWeights[i]
            }

            self.lock.lock()
            let levels = self.levelsCallback
            let audio = self.audioCallback
            self.lock.unlock()

            levels?(bars)

            if let audio {
                self.resampleQueue.async {
                    let block = self.resampler.resample(samples)
                    if !block.isEmpty { audio(block) }
                }
            }
        }

        do {
            try engine.start()
            mlog("AudioRecorder: started")
        } catch {
            mlog("AudioRecorder start failed: \(error)")
        }
    }

    /// Stops capture. Every block captured before this returns has already
    /// been handed to `onAudio` — the drain below guarantees it — so the
    /// consumer can treat the next call as "the take is complete".
    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        lock.lock()
        levelsCallback = nil
        audioCallback = nil
        lock.unlock()

        resampleQueue.sync {}   // drain barrier
        mlog("AudioRecorder: stopped")
    }

    // MARK: - System default input (read-only)

    /// Read the system default input device. This is a GET — sandbox-safe and
    /// allowed in the Mac App Store (only SETTING the default is a violation).
    /// Used to skip the AUHAL rebind when the user's pick already is the
    /// default; rebinding to the same device broke capture on macOS 26.
    static func currentDefaultInputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }
}

/// Linear resampler that survives being fed one block at a time.
///
/// Resampling a take in one pass is trivial; doing it block by block is not,
/// because the read position lands between input samples and the next block
/// has to pick up exactly where the last one left off. This carries both the
/// fractional position and the previous block's last sample, so concatenating
/// the outputs equals resampling the whole take at once.
private struct StreamingResampler {
    /// target rate / native rate, e.g. 16000 / 44100.
    let ratio: Double

    /// Next read index in input samples, relative to the start of the block
    /// being handed in. Negative means "one sample before this block" — that
    /// sample is `carry`.
    private var position: Double = 0
    private var carry: Float = 0

    init(ratio: Double) { self.ratio = ratio }

    mutating func resample(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard ratio != 1.0 else { return input }

        let step = 1.0 / ratio
        var output = [Float]()
        output.reserveCapacity(Int(Double(input.count) * ratio) + 1)

        var pos = position
        while true {
            let i0 = Int(pos.rounded(.down))
            let i1 = i0 + 1
            if i1 >= input.count { break }
            let frac = Float(pos - Double(i0))
            let s0 = i0 < 0 ? carry : input[i0]
            output.append(s0 * (1.0 - frac) + input[i1] * frac)
            pos += step
        }

        carry = input[input.count - 1]
        position = pos - Double(input.count)
        return output
    }
}
