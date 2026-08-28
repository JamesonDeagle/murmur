import Testing
import Foundation
@testable import Murmur

/// The property the streaming session exists to preserve: transcribing while
/// the user talks must produce the same text as transcribing the finished
/// take. The reference transcript is produced by a single `whisper_full` over
/// the identical buffer.
///
/// Needs a model and a raw 16 kHz mono float32 file, so it is opt-in:
///
///     MURMUR_TEST_MODEL=~/Library/.../ggml-large-v3-turbo.bin \
///     MURMUR_TEST_AUDIO=/path/speech.raw \
///     MURMUR_TEST_EXPECT=/path/batch.txt \
///     swift test
@Test func sessionMatchesWholeTake() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let modelPath = env["MURMUR_TEST_MODEL"],
          let audioPath = env["MURMUR_TEST_AUDIO"] else {
        print("skipped: set MURMUR_TEST_MODEL and MURMUR_TEST_AUDIO to run")
        return
    }

    let raw = try Data(contentsOf: URL(fileURLWithPath: audioPath))
    let samples = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(samples.count > 16_000)

    let engine = WhisperEngine()
    await engine.loadModel(name: modelPath.contains("turbo") ? "turbo" : "large")
    await engine.setLanguage("ru")

    // Feed it the way the recorder does: small blocks, in order.
    let blockSize = 1_600   // 100 ms
    await engine.beginSession()
    for start in stride(from: 0, to: samples.count, by: blockSize) {
        await engine.append(Array(samples[start..<min(start + blockSize, samples.count)]))
    }
    let transcript = await engine.endSession()

    let text = try #require(transcript)
    #expect(!text.isEmpty)
    print("session transcript: \(text.count) chars")

    if let expectPath = env["MURMUR_TEST_EXPECT"] {
        let expected = try String(contentsOfFile: expectPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == expected, "streaming transcript differs from the whole-take reference")
    }

    await engine.cleanup()
}
