# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Murmur — нативное macOS menubar-приложение для speech-to-text. Работает полностью локально на Apple Silicon через whisper.cpp (C API + Metal GPU). Один .app файл, zero dependencies, drag-to-install.

**Версия:** 3.12 (native Swift)
**Платформа:** macOS 14+ (Sonoma), Apple Silicon (M1/M2/M3/M4)
**Стек:** Swift 6 + SwiftUI + whisper.cpp (static linking) + Metal + FluidAudio (Parakeet Core ML / ANE) + WhisperKit (Argmax, whisper-large-v3 на ANE) + mlx-audio-swift (Voxtral 4B, Qwen3-ASR 1.7B на MLX/GPU)
**UI:** Liquid Glass (macOS 26 Tahoe) с fallback на ultraThinMaterial для macOS 14–15

## Quick Start

```bash
# Build + create .app bundle with icon, code-sign, install в /Applications
./build-app.sh

# Run
open /Applications/Murmur.app
# или для отладки со stdout: .build/release/Murmur

# Plain SPM build (без bundle)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

# Tests (SPM target MurmurTests)
swift test
```

**Использование:** Option+Space → говори → Option+Space → текст вставляется в активное поле.

> [!warning] Полный Xcode обязателен (не только CLI tools) — нужен Metal framework. Если стоит не он:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` или передавай `DEVELOPER_DIR=` каждой команде сборки.

## Architecture

### Data Flow
```
Option+Space → AppState.toggle()
  → AudioRecorder.start() [AVAudioEngine, native format 44.1kHz]
    → tap callback: copy PCM samples + compute RMS for waveform
  → Option+Space again
  → AudioRecorder.stop()
    → resample 44.1kHz → 16kHz (linear interpolation)
    → normalize to peak ~0.9
    → return [Float]
  → TranscriptionEngine.transcribe([Float])
    → whisper_full() [C API, Metal GPU]
    → extract segments → joined text
  → TextPaster.paste(text)
    → NSPasteboard + CGEvent Cmd+V
    → restore clipboard after 0.5s
```

### State Machine
```
.loading → (model loads) → .idle → (Option+Space) → .recording → (Option+Space) → .transcribing → .idle
                                                       ↓ (Escape)
                                                     .idle
```

### Threading Model
- **AppState** — `@MainActor` singleton
- **AudioRecorder** — audio tap runs on audio thread, `NSLock` protects `rawSamples[]` and `levelsCallback`
- **TranscriptionEngine** — Swift `actor` (serialized access to whisper context)
- **WaveformPanel** — `@MainActor`

## File Structure

```
Murmur/
├── Package.swift              # SPM manifest: CWhisper + Murmur targets
├── CLAUDE.md                  # This file
├── Info.plist                 # App bundle metadata (icon, permissions, LSUIElement)
├── build-app.sh               # Build script: swift build + .app bundle assembly
├── Murmur-3.1.dmg            # Release DMG installer
├── Assets/
│   └── AppIcon.icns           # App icon (1930s cartoon cat, all sizes 16-1024px)
├── Sources/
│   ├── Murmur/
│   │   ├── Murmur.swift       # @main, MenuBarExtra, NSApplicationDelegateAdaptor
│   │   ├── AppState.swift     # Singleton state, setup(), toggle(), cancel(), mlog()
│   │   ├── AudioRecorder.swift    # AVAudioEngine capture, resample, normalize, device selection
│   │   ├── InputDeviceManager.swift  # CoreAudio input device enumeration
│   │   ├── TranscriptionEngine.swift  # whisper.cpp wrapper (actor)
│   │   ├── HotkeyManager.swift   # Carbon RegisterEventHotKey (Option+Space)
│   │   ├── TextPaster.swift       # NSPasteboard + CGEvent Cmd+V
│   │   ├── MenuBarView.swift      # SwiftUI menu (model select, mic select, quit)
│   │   ├── WaveformView.swift     # Liquid Glass UI: waveform bars + OrbitalLoader
│   │   └── WaveformOverlay.swift  # NSPanel floating window
│   └── CWhisper/
│       ├── module.modulemap   # Links whisper + ggml libs
│       ├── shim.c             # Empty (required by SPM)
│       └── include/shim.h     # Re-exports whisper.h
├── include/                   # whisper.cpp C headers (whisper.h, ggml*.h)
├── lib/                       # Static libraries (.a files)
│   ├── libwhisper.a
│   ├── libggml.a, libggml-base.a, libggml-cpu.a
│   ├── libggml-metal.a, libggml-blas.a
│   └── ggml-metal-embed.metal # Metal shaders (embedded at link time)
└── Tests/MurmurTests/
```

## Key Components

### AppState.swift
- `mlog()` — file-based logging to `~/.murmur-debug.log` (NSLog doesn't work for menubar apps)
- `startSetup()` — called from NSApplicationDelegate after 0.5s delay (MenuBarExtra `.task`/`.onAppear` don't fire)
- `setup()` — checks mic permission, checks Accessibility (`AXIsProcessTrustedWithOptions` с prompt), registers hotkeys, loads model
- `toggle()` — state machine: idle→recording→transcribing→idle
- Accidental press protection: recording < 1s → auto-cancel

### AudioRecorder.swift
- **CRITICAL:** PCM buffers from AVAudioEngine tap are REUSED by the engine. Must copy samples immediately in callback, NOT store buffer references.
- **Input device selection:** Temporarily switches system default input device for recording, restores on stop. `AudioUnitSetProperty` approach doesn't work — causes `-10868 InitializeActiveNodesInInputChain` error.
- Native mic format: 44100Hz mono (on most Macs)
- Resampling: linear interpolation to 16kHz
- Normalization: scale peak to 0.9 (mic raw levels are ~0.03-0.05, too quiet for whisper)
- Waveform: 11 bars with symmetric weights [0.3..1.0..0.3], RMS * 15.0

### InputDeviceManager.swift
- CoreAudio device enumeration: lists all devices with input channels
- Built-in detection: `kAudioDeviceTransportTypeBuiltIn` OR UID contains "builtin" (some Macs report non-standard transport type)
- Default: built-in microphone (persists even when Bluetooth speaker connected)
- Selection saved in `UserDefaults("inputDeviceUID")`

### TranscriptionEngine.swift
- Downloads GGML models from HuggingFace on first launch
- Models stored in `~/Library/Application Support/Murmur/models/`
- Warmup: transcribes 1s silence on load (triggers Metal shader JIT)
- `flash_attn = false` (true causes compute buffer size mismatch)
- `initial_prompt` — guides punctuation style

### HotkeyManager.swift
- Carbon Events API: `RegisterEventHotKey()` / `UnregisterEventHotKey()`
- Option key = `optionKey` modifier, Space = keyCode 49
- Global hotkey works in any app, any space

### TextPaster.swift
- Saves current clipboard → sets text → simulates Cmd+V → restores clipboard after 0.5s
- CGEvent with `.maskCommand` flag, virtual key 0x09 (V)
- Debug logging: clipboard verify, CGEvent creation check, `AXIsProcessTrusted()` status
- **Requires Accessibility permission** (System Settings → Privacy & Security → Accessibility)

### WaveformView.swift
- **Recording:** Liquid Glass capsule (`.glassEffect(.regular, in: Capsule())` on macOS 26+) с fixed-height pill (68pt), бары `Color.primary` анимируются внутри
- **Transcribing:** Orbital loader — 8 точек `Color.primary` на внешней орбите + 5 на внутренней (counter-rotating) + пульсирующее центральное свечение, всё внутри Liquid Glass circle
- **Адаптивные цвета:** все элементы используют `Color.primary` — чёрные в светлой теме, белые в тёмной
- Fallback для macOS 14–15: `.ultraThinMaterial` вместо `.glassEffect()`
- Spring-анимации появления/скрытия (response: 0.35, damping: 0.78)

### WaveformOverlay.swift
- NSPanel: borderless, floating, ignoresMouseEvents, works on all spaces
- Size: 260×140 pt, positioned center + 60pt from bottom
- Hide delay: 0.4s (для spring-анимации)

## Models

| Name | File | Size | Speed |
|------|------|------|-------|
| turbo | ggml-large-v3-turbo.bin | ~1.5 GB | Fast |
| large | ggml-large-v3.bin | ~3 GB | Best quality |

Source: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/`
Local: `~/Library/Application Support/Murmur/models/`

## Known Issues & Workarounds

### whisper.cpp 1.8.4: detect_language bug
**Problem:** `detect_language=true` + `language="auto"` → 0 segments (decoder produces nothing)
**Workaround:** Use explicit `language="ru"`, `detect_language=false`
**Impact:** Currently hardcoded to Russian. To support other languages, set language explicitly.

### AVAudioEngine buffer reuse
**Problem:** `AVAudioPCMBuffer` from tap callback is recycled by the engine after callback returns. Storing buffer references leads to corrupted/zero data.
**Fix:** Copy float samples into `[Float]` array immediately inside the callback using `Array(UnsafeBufferPointer(...))`.

### Mic audio levels very low
**Problem:** Raw mic input on MacBook is max ~0.03-0.05 (whisper needs ~0.1+)
**Fix:** Normalize audio to peak 0.9 before passing to whisper. Gain capped at 50x to avoid amplifying pure noise.

### MenuBarExtra lifecycle
**Problem:** `.task{}` and `.onAppear{}` don't fire for MenuBarExtra content until menu is opened.
**Fix:** Use `@NSApplicationDelegateAdaptor` with `applicationDidFinishLaunching` + `DispatchQueue.main.asyncAfter(0.5s)`.

### LaunchServices binary cache
**Problem:** macOS caches app binary signatures. After rebuilding, the old version may launch.
**Fix:** Change CFBundleIdentifier or delete old .app and create at new path. `lsregister -kill` or `open -n` may help.

### mlog instead of NSLog
**Problem:** NSLog/os.log are filtered by macOS for GUI apps (info level messages don't appear).
**Fix:** File-based logging to `~/.murmur-debug.log`.

### Accessibility permission reset after rebuild
**Problem:** macOS ties Accessibility permission to the app binary signature. After `./build-app.sh` the binary changes and `AXIsProcessTrusted()` returns `false` → Cmd+V paste fails silently.
**Fix:** `build-app.sh` now code-signs with a stable developer identity (`codesign --force --deep --sign`), so permission persists across rebuilds. If signing identity is unavailable, falls back to ad-hoc (`sign -`) and permission will need re-granting.
**First launch:** `AXIsProcessTrustedWithOptions` with prompt automatically shows system dialog asking user to grant Accessibility.

## Build & Distribution

### Prerequisites
- Xcode (full, not just Command Line Tools) — needed for Metal framework
- If Xcode path is wrong: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

### Build
```bash
cd ~/Desktop/Murmur
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
```

### Create .app Bundle
```bash
./build-app.sh
```
Скрипт выполняет: `swift build -c release` → создаёт `Murmur.app/` → копирует бинарник, `Info.plist`, `Assets/AppIcon.icns` → code sign (developer identity или ad-hoc) → копирует в `/Applications/`.

**Info.plist** (уже в репо):
- `CFBundleIconFile = AppIcon` — иконка приложения
- `LSUIElement = true` — hide from Dock (menubar-only)
- `NSMicrophoneUsageDescription` — mic permission string
- `NSHighResolutionCapable = true`
- `CFBundleExecutable = Murmur`

### Create DMG
```bash
DMG_DIR="/tmp/murmur-dmg"
mkdir -p "$DMG_DIR"
cp -R /Applications/Murmur.app "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "Murmur" -srcfolder "$DMG_DIR" -ov -format UDZO Murmur-3.1.dmg
```
DMG собирается из подписанного бандла в `/Applications/`.

### Static Libraries
Built from whisper.cpp source:
```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -B build -DGGML_METAL=ON -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
# Copy lib/*.a and include/*.h to Murmur project
```

## Whisper.cpp C API Reference (used in this project)

```c
// Context
whisper_context_params whisper_context_default_params(void);
whisper_context* whisper_init_from_file_with_params(const char* path, whisper_context_params params);
void whisper_free(whisper_context* ctx);

// Transcription
whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy);
int whisper_full(whisper_context* ctx, whisper_full_params params, const float* samples, int n_samples);

// Results
int whisper_full_n_segments(whisper_context* ctx);
const char* whisper_full_get_segment_text(whisper_context* ctx, int i_segment);
```

**Key params:**
- `whisper_context_params.use_gpu = true` — Metal acceleration
- `whisper_context_params.flash_attn = false` — disabled (compatibility)
- `whisper_full_params.language = "ru"` — explicit language (NOT "auto")
- `whisper_full_params.detect_language = false` — disabled (bug workaround)
- `whisper_full_params.initial_prompt` — guides punctuation/style
- `whisper_full_params.no_context = true` — don't carry context between calls
- `whisper_full_params.suppress_blank = false` — don't drop quiet segments

## History

- **v1.0** — Hammerspoon + Python daemon (mlx-whisper). Worked but required Hammerspoon + Python + Homebrew.
- **v2.0** — Published to GitHub with install script, DMG, README.
- **v3.0** — Native Swift app. Single .app, no dependencies. whisper.cpp C API + Metal GPU.
- **v3.1** — App icon (1930s cartoon cat). Liquid Glass UI (macOS Tahoe). Orbital transcription loader. Adaptive colors (`Color.primary` — dark/light theme). Input device selector (Microphone menu, defaults to built-in). Accessibility auto-prompt on first launch. Code signing for stable permissions. Thread-safety fixes (AudioRecorder race condition, model switch guard). Cleanup on quit. Auto-install to `/Applications/`.
- **v3.2** — Multi-monitor fix: waveform overlay centers on the screen with the cursor (was using `NSScreen.main` once at panel creation, drifted on display changes). Use-after-free fix on model switch (`whisper_full` SIGSEGV when Option+Space hit during 3 GB large download — ctx is now nil'd before `whisper_free`, and switching holds `state = .loading` for the entire download+init). Model download progress in menu bar (size, speed, ETA via `URLSessionDownloadDelegate` with EMA-smoothed bytes/sec). Persists last-used model across launches (UserDefaults `activeModel`).
- **v3.3** — Pause / Resume in the menu: free the whisper context (~1.5–3 GB CPU RAM + Metal GPU buffers) without quitting the app. New `.paused` `RecordingState`; `AppState.pauseModel()` calls `engine.cleanup()`, `resumeModel()` reuses the normal load path so the user gets the same progress UI. Option+Space is a no-op while paused (logged) — picking the active model in the menu also resumes. Model menu and Microphone menu remain enabled in `.paused` so users can switch model directly from a paused state.
- **v3.12** — `TextPaster.paste` больше не восстанавливает предыдущий буфер обмена через 0.5s. Текст остаётся на clipboard насовсем (до следующей диктовки). Use case: пользователь забывает кликнуть в input field, симулированный Cmd+V уходит в пустоту, но текст теперь всё равно ждёт в буфере — можно ручным Cmd+V вставить куда нужно. Trade-off: «вежливая» restore-логика убрана, прежний буфер не сохраняется. Принято осознанно — потерять надиктованный абзац хуже чем потерять то что было в буфере раньше.
- **v3.11** — После A/B тестирования всех шести движков на реальной русской диктовке whisper-turbo (whisper.cpp + Metal) показал лучшее качество транскрипции. Default для новых установок изменён `.parakeetV3` → `.whisperTurbo`. Порядок в `SpeechModelOption.allCases` переставлен — turbo первым, parakeet вторым, дальше whisper-ane, large, voxtral, qwen3. `menuLabel`: "(recommended)" перенесён с parakeet на turbo. Существующие пользователи сохраняют свой выбор через UserDefaults restore в `AppState.init()` — только свежие установки получают новый дефолт.
- **v3.10** — Fix: Voxtral / Qwen3 (MLX) крэшили приложение при загрузке моделей. Причина: `swift build` из CLI **не запускает Metal-компилятор**, поэтому `mlx-swift` не генерировал `default.metallib` и MLX runtime падал с `Failed to load the default metallib`. Решение: `build-app.sh` переключён на `xcodebuild build -scheme Murmur -configuration Release ARCHS=arm64`, который правильно компилирует Metal через установленный Metal Toolchain (отдельный Xcode component — нужен `xcodebuild -downloadComponent MetalToolchain` один раз). Скрипт копирует все `*.bundle` из `Build/Products/Release` в `Murmur.app/Contents/Resources/`, MLX runtime находит `default.metallib` через `NS::Bundle::allBundles()`. `ARCHS=arm64` обязательно — иначе xcodebuild пытается universal binary и линковка падает на whisper.cpp `lib/*.a` (arm64-only).
- **v3.9** — Авто-удаление неиспользуемых моделей через 3 дня. Новый протокольный метод `SpeechEngine.cachedModelPaths(name:) async -> [URL]` (default impl `[]` — engines без известного кэш-пути пропускаются). Override'нут в WhisperEngine (`~/Library/Application Support/Murmur/models/ggml-*.bin`), ParakeetEngine (`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`), MLXAudioEngine (два пути: `~/.cache/huggingface/hub/mlx-audio/<repo_underscores>` + `~/.cache/huggingface/hub/models--<org>--<name>`). WhisperKit оставлен с default — внутренний путь у Argmax не публичный, авто-чистка пропускает. AppState: `lastUsed: [String: Date]` в UserDefaults (ключ `modelLastUsed`), `touchLastUsed(_:)` на каждом успешном transcribe, `pruneStaleModels()` в начале `setup()` до `loadModel`. TTL = 3 × 24 × 60 × 60 секунд. First-run amnesty: при первом запуске v3.9 записывается `modelCacheAmnestyAt = Date()` и удалений не происходит — даёт 3-дневное окно legacy-установкам. Если активная модель сама протухла — она удалится и сразу качается заново через стандартный progress UI. После prune timestamp обнуляется чтобы новый TTL отсчитывался с момента следующего скачивания.
- **v3.8** — Два новых движка через `mlx-audio-swift` (Blaizzy, MIT): Voxtral Mini 4B Realtime (Mistral AI, 4-bit quantization, ~2 GB) и Qwen3-ASR 1.7B (Alibaba, bf16, ~3.4 GB, **52 языка включая русский и украинский**). Оба через универсальный `MLXAudioEngine` actor с enum `Variant` внутри — модель грузится через статический `fromPretrained(repoID)` каждого конкретного класса (`VoxtralRealtimeModel`, `Qwen3ASRModel`), API общий через `STTGenerationModel` protocol. Compute pool: **MLX/Metal GPU** (не ANE) — отличается от Parakeet и WhisperKit. Это экспериментальные модели для тестов качества vs Parakeet. Sendable workaround через `@preconcurrency import MLX/MLXAudioSTT/MLXAudioCore` (Module-derived классы pre-date Swift 6 strict). `EngineKind.mlxAudio` — четвёртый tag; `SpeechModelOption.voxtralMini` и `.qwen3Asr` — два новых case (raw values "voxtral", "qwen3"). Без публичного download progress API — UI fallback "Downloading & loading". Bundle вырос до ~30 MB (MLX runtime + swift-transformers + swift-nio transitive deps). Меню теперь 6 моделей: parakeet, whisper-ane, voxtral, qwen3, turbo, large.
- **v3.7** — Tokenizer-artifact sanitizer перед TextPaster.paste. Parakeet TDT v3 ставит `<unk>` вокруг типографских символов которых нет в его SentencePiece vocab (русские «ёлочки», curly quotes), результат был типа `<unk>Написать в техподдержку<unk>` вместо `"Написать в техподдержку"`. `AppState.sanitizeTranscript(_:)` парные `<unk>...<unk>` в коротком окне (≤120 символов) превращает в double-quote pair, одиночные стрипает, плюс убирает `<pad>/<s>/</s>/<bos>/<eos>` и чинит double-space + space-before-punct. Whisper-family движков не касается (BPE токенизатор покрывает Unicode), но безопасно для всех.
- **v3.6** — WhisperKit (Argmax) добавлен как четвёртый движок — whisper-large-v3-turbo, скомпилированный в Core ML, бегает на Apple Neural Engine. Закрывает gap «whisper качество + ANE скорость + рабочее auto-language-detection». ~626 MB, ~42× RTF, ANE-резидент. Working language auto-detection без хардкода `language="ru"` (whisper.cpp 1.8.4 detect_language bug это **не** WhisperKit). Архитектура: новый `WhisperKitEngine: SpeechEngine` actor (через `@preconcurrency import WhisperKit` чтобы обойти Swift 6 strict concurrency на не-Sendable `WhisperKit` open class). `EngineKind.whisperKit` третий tag. `SpeechModelOption.whisperKitTurbo` ("whisper-ane") новый case. SPM dependency `argmaxinc/WhisperKit` from 0.9.0. Без явного download progress API — UI показывает "Downloading & compiling" без bytes/MB-s. ModelComputeOptions: melCompute=cpuAndGPU, audioEncoderCompute=ANE, textDecoderCompute=ANE, prefillCompute=cpuOnly (ANE-first layout).
- **v3.5** — Parakeet promoted to default model for new installs. `AppState.activeModel` now initializes to `.parakeetV3`; `SpeechModelOption` declaration order rearranged so Parakeet shows first in the Model menu with a "(recommended)" hint in its label. Existing users keep whatever they previously picked — `UserDefaults["activeModel"]` is read first and only the absence of a saved value triggers the new default. README rewritten to lead with Parakeet (multilingual, ANE-resident, ~66 MB) and to frame whisper turbo/large as opt-in alternatives for Russian-only workflows.
- **v3.4** — Parakeet TDT v3 as a third speech engine, alongside whisper turbo/large. FluidAudio SPM dependency (0.14.5+) wraps the Core ML port — runs on Apple Neural Engine (ANE), ~66 MB working memory vs whisper's 1.5–3 GB, ~110× RTF on M-series, leaves Metal GPU free. Critically: 25 European languages + JP + ZH with **automatic language detection** built in, sidestepping the whisper.cpp 1.8.4 `detect_language` bug that forced Murmur to hardcode `language="ru"`. Architecture: new `SpeechEngine` protocol in `SpeechEngine.swift`; `TranscriptionEngine.swift` renamed to `WhisperEngine.swift`; new `ParakeetEngine.swift`. `AppState.engine` is now `(any SpeechEngine)?` and `currentEngineKind` tracks which actor type is live so cross-engine switches (whisper↔parakeet) destroy the old one. `SpeechModelOption` enum (turbo / large / parakeet) drives the Model menu; UserDefaults raw values match old strings ("turbo", "large") so v3.3 settings migrate cleanly. `DownloadProgress` extended with `fraction` + `phase` (FluidAudio emits fraction + phase enum, no byte counts — UI falls back to "Downloading 2/5  40%" instead of MB/s+ETA for Parakeet).

## Debug

```bash
# Watch live log
tail -f ~/.murmur-debug.log

# Check model exists
ls -la ~/Library/Application\ Support/Murmur/models/

# Kill running instance
pkill -f Murmur.app/Contents/MacOS/Murmur

# Launch with stdout visible
/path/to/Murmur.app/Contents/MacOS/Murmur
```
