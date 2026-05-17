import Foundation
import CoreML
// WhisperKit's public types (WhisperKit, DecodingOptions, TranscriptionResult)
// pre-date Swift 6's strict concurrency annotations. @preconcurrency silences
// the "non-Sendable value crosses actor boundary" errors that come from
// holding a `WhisperKit` instance inside our actor and awaiting on it.
// Safe because we never share the pipe instance outside this actor.
@preconcurrency import WhisperKit

/// WhisperKit-backed speech engine: openai/whisper-large-v3-turbo compiled to
/// Core ML, executed primarily on the Apple Neural Engine.
///
/// Why this exists alongside `WhisperEngine` (whisper.cpp + Metal) and
/// `ParakeetEngine` (Parakeet + ANE):
///
/// - **Quality of whisper** at multilingual transcription — including the
///   tricky Russian dictation we hardcode `language="ru"` for in
///   `WhisperEngine` — without the whisper.cpp 1.8.4 `detect_language` bug.
///   WhisperKit ships its own decoder that honours `detectLanguage = true`.
/// - **ANE residency** like Parakeet — leaves the Metal GPU free, doesn't
///   compete with Xcode builds / video apps for GPU memory.
/// - **~2× faster than whisper.cpp** Core ML on the same hardware
///   (Argmax benchmarks), and large-v3-turbo at ~42× real-time on M-series
///   ANE-only matches Parakeet's class in throughput.
///
/// Trade-off: model is ~626 MB on disk (turbo) vs ~600 MB for Parakeet,
/// working memory similar to Parakeet but slightly higher.
actor WhisperKitEngine: SpeechEngine {
    /// The WhisperKit name for openai/whisper-large-v3-turbo. Argmax's
    /// recommended default for "best multilingual accuracy" in the README.
    /// If you want full large-v3 swap to "openai_whisper-large-v3" — slower,
    /// not a meaningful WER win for dictation use.
    private static let modelName = "openai_whisper-large-v3-turbo"

    private var pipe: WhisperKit?

    func loadModel(
        name: String,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async {
        mlog("WhisperKitEngine.loadModel: \(name)")

        // Free previous if any. WhisperKit doesn't expose an explicit
        // cleanup — dropping the reference releases the Core ML model,
        // and we nil it before reassigning so the actor's queue never
        // sees a stale pointer during the suspend on `try await WhisperKit(...)`.
        if pipe != nil {
            pipe = nil
        }

        // Emit a coarse "loading" phase since WhisperKit doesn't surface
        // per-byte download progress publicly. The model download from
        // HuggingFace argmaxinc/whisperkit-coreml happens transparently
        // inside the WhisperKit init on first use.
        onProgress?(DownloadProgress(
            modelName: "whisper-ane",
            bytesDownloaded: -1,
            totalBytes: -1,
            bytesPerSecond: 0,
            fraction: 0.0,
            phase: "Downloading & compiling"
        ))

        do {
            // ANE-first compute layout:
            //   - melCompute on CPU+GPU (no large ANE win on FFT-style ops)
            //   - audioEncoder + textDecoder on ANE (where the real work is)
            //   - prefill on CPU (small, latency-sensitive)
            // These are the defaults WhisperKit picks on macOS 14+ anyway,
            // but stating them explicitly so future maintainers see intent.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuOnly
            )
            let config = WhisperKitConfig(
                model: Self.modelName,
                computeOptions: compute
            )

            let pipe = try await WhisperKit(config)
            self.pipe = pipe
            mlog("WhisperKitEngine: model loaded (\(Self.modelName))")
        } catch {
            mlog("WhisperKitEngine.loadModel failed: \(error)")
            pipe = nil
        }
    }

    func transcribe(audio: [Float]) async -> String? {
        guard !audio.isEmpty else { return nil }
        guard let pipe = pipe else {
            mlog("WhisperKitEngine.transcribe: pipeline not loaded")
            return nil
        }

        let maxVal = audio.map { abs($0) }.max() ?? 0
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
        mlog("WhisperKitEngine.transcribe: \(audio.count) samples, max=\(maxVal), rms=\(rms)")

        do {
            // language: nil + detectLanguage: true → whisper figures it out.
            // chunkingStrategy: .vad keeps long-ish utterances reasonable; for
            // typical Option+Space dictation (1–30s) it's a no-op.
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: nil,
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                suppressBlank: true,
                chunkingStrategy: .vad
            )

            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: audio,
                decodeOptions: options
            )

            let text = results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let detected = results.first?.language {
                mlog("WhisperKitEngine result: detected=\(detected) text='\(text.prefix(80))'")
            } else {
                mlog("WhisperKitEngine result: text='\(text.prefix(80))'")
            }
            return text.isEmpty ? nil : text
        } catch {
            mlog("WhisperKitEngine.transcribe failed: \(error)")
            return nil
        }
    }

    func cleanup() async {
        // WhisperKit has no explicit unload — ARC + dropped CoreML model
        // refs is what we have. Setting nil here releases the heaviest
        // chunk (encoder + decoder Core ML models).
        pipe = nil
        mlog("WhisperKitEngine cleaned up")
    }
}
