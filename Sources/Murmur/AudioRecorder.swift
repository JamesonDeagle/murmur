import AVFoundation
import Accelerate
import CoreAudio
import AudioToolbox

class AudioRecorder {
    private var engine: AVAudioEngine?
    private var rawSamples: [Float] = []
    private var nativeSampleRate: Double = 44100
    private let targetSampleRate: Double = 16000
    private var levelsCallback: (([Float]) -> Void)?
    private let numBars = 11
    private let barWeights: [Float] = [0.3, 0.5, 0.7, 0.85, 0.95, 1.0, 0.95, 0.85, 0.7, 0.5, 0.3]
    private let lock = NSLock()

    func start(deviceID: AudioDeviceID? = nil, onLevels: @escaping ([Float]) -> Void) {
        lock.lock()
        rawSamples = []
        lock.unlock()
        levelsCallback = onLevels

        engine = AVAudioEngine()
        guard let engine = engine else { return }

        let inputNode = engine.inputNode

        // Point THIS engine's input at the requested device, without touching
        // the system-wide default input (which would be a sandbox violation —
        // modifying a system preference is not covered by the audio-input
        // entitlement and gets the app rejected in App Review).
        //
        // Order is load-bearing: the device must be set on the input node's
        // audio unit BEFORE we query its output format or install the tap, or
        // we read the format of the wrong (old default) device. On any failure
        // we log and fall through to the system default — never crash.
        if let deviceID = deviceID, let au = inputNode.audioUnit {
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
                mlog("AudioRecorder: input node bound to device \(deviceID)")
            } else {
                mlog("AudioRecorder: AudioUnitSetProperty(CurrentDevice) failed (\(st)) — using system default")
            }
        } else if deviceID != nil {
            mlog("AudioRecorder: inputNode.audioUnit is nil — using system default")
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate
        mlog("AudioRecorder: native format sr=\(nativeFormat.sampleRate) ch=\(nativeFormat.channelCount)")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }
            guard let floatData = pcmBuffer.floatChannelData?[0] else { return }
            let count = Int(pcmBuffer.frameLength)

            // Copy samples immediately — buffer is reused by the engine after callback returns
            let samples = Array(UnsafeBufferPointer(start: floatData, count: count))
            self.lock.lock()
            self.rawSamples.append(contentsOf: samples)
            let callback = self.levelsCallback
            self.lock.unlock()

            // Compute RMS for visualization
            var rms: Float = 0
            vDSP_rmsqv(floatData, 1, &rms, vDSP_Length(count))
            let level = min(1.0, rms * 15.0)

            var bars = [Float](repeating: 0, count: self.numBars)
            for i in 0..<self.numBars {
                bars[i] = level * self.barWeights[i]
            }
            callback?(bars)
        }

        do {
            try engine.start()
            mlog("AudioRecorder: started")
        } catch {
            mlog("AudioRecorder start failed: \(error)")
        }
    }

    @discardableResult
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        lock.lock()
        levelsCallback = nil
        let allSamples = rawSamples
        rawSamples = []
        lock.unlock()

        guard !allSamples.isEmpty else {
            mlog("AudioRecorder: no samples captured")
            return []
        }

        let rawMax = allSamples.map { abs($0) }.max() ?? 0
        var rawRms: Float = 0
        vDSP_rmsqv(allSamples, 1, &rawRms, vDSP_Length(allSamples.count))
        mlog("AudioRecorder: raw samples=\(allSamples.count) at \(nativeSampleRate)Hz, max=\(rawMax), rms=\(rawRms)")

        // Resample to 16kHz if needed
        var output: [Float]
        if nativeSampleRate != targetSampleRate {
            let ratio = targetSampleRate / nativeSampleRate
            let outputCount = Int(Double(allSamples.count) * ratio)
            output = [Float](repeating: 0, count: outputCount)

            for i in 0..<outputCount {
                let srcIdx = Double(i) / ratio
                let idx0 = Int(srcIdx)
                let idx1 = min(idx0 + 1, allSamples.count - 1)
                let frac = Float(srcIdx - Double(idx0))
                output[i] = allSamples[idx0] * (1.0 - frac) + allSamples[idx1] * frac
            }
        } else {
            output = allSamples
        }

        // Normalize audio to peak ~0.9 so whisper.cpp can detect speech
        let peak = output.map { abs($0) }.max() ?? 0
        if peak > 0.001 {
            let gain = min(0.9 / peak, 50.0) // Cap gain at 50x to avoid amplifying pure noise
            if gain > 1.5 {
                mlog("AudioRecorder: normalizing audio, peak=\(peak), gain=\(gain)x")
                var gainVar = gain
                vDSP_vsmul(output, 1, &gainVar, &output, 1, vDSP_Length(output.count))
            }
        }

        let finalMax = output.map { abs($0) }.max() ?? 0
        var finalRms: Float = 0
        vDSP_rmsqv(output, 1, &finalRms, vDSP_Length(output.count))
        mlog("AudioRecorder: final output=\(output.count) samples, max=\(finalMax), rms=\(finalRms)")

        return output
    }
}
