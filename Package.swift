// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT v3 ASR via Core ML + Apple Neural Engine.
        // Multilingual (25 European languages + Japanese + Chinese) with built-in
        // language detection — frees us from the whisper.cpp Russian-hardcode workaround.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // WhisperKit — whisper-large-v3 etc. compiled to CoreML, running on ANE.
        // Same whisper quality as our whisper.cpp+Metal path but ~2× faster
        // and shares the ANE with Parakeet so no GPU pressure.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // MLX-Audio Swift SDK — Apple's MLX framework + swift-transformers,
        // gives us Voxtral Mini 4B Realtime and Qwen3-ASR-1.7B for testing.
        // Runs on Apple Silicon GPU/MPS via MLX (not ANE).
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
    ],
    targets: [
        .systemLibrary(
            name: "CWhisper",
            path: "Sources/CWhisper"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "CWhisper",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ],
            path: "Sources/Murmur",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "lib",
                    "-lwhisper", "-lggml", "-lggml-base", "-lggml-cpu",
                    "-lggml-metal", "-lggml-blas",
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
