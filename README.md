<p align="center">
  <img src="Assets/icon-preview.png" width="180" alt="Murmur icon" />
</p>

<h1 align="center">Murmur</h1>

<p align="center">
  Native macOS menubar speech-to-text. 100% local on Apple Silicon.<br>
  <b>Press Option+Space, talk, press again — text appears wherever your cursor is.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2FM2%2FM3%2FM4-green" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/UI-Liquid_Glass-purple" alt="Liquid Glass">
  <img src="https://img.shields.io/badge/whisper.cpp-Metal_GPU-orange" alt="whisper.cpp">
</p>

> **Six speech engines, you pick in the Model menu.**
> - **turbo** *(default, recommended)* — whisper-large-v3-turbo via whisper.cpp + Metal GPU. **Best transcription quality** based on our A/B tests on Russian dictation. ~1.5 GB, 1–2s per phrase. Russian by default (one line to switch).
> - **parakeet** — NVIDIA Parakeet TDT v3 on Apple Neural Engine. Lightest option, 25 EU + JP + ZH with auto-detect. ~600 MB, ~66 MB working memory, ~110× real-time. Pick this when whisper is overkill.
> - **whisper-ane** — whisper-large-v3-turbo on ANE via Argmax WhisperKit. Whisper quality with ANE residency + working auto-detect. ~626 MB.
> - **large** — whisper.cpp + Metal, full large model (not turbo). ~3 GB, higher accuracy ceiling, slower.
> - **voxtral** *(experimental)* — Voxtral Mini 4B Realtime (Mistral AI) via MLX. ~2 GB. Runs on Apple Silicon GPU.
> - **qwen3** *(experimental)* — Qwen3-ASR-1.7B (Alibaba) via MLX. **52 languages including Russian + Ukrainian**. ~3.4 GB.

## Quick start (60 seconds)

1. **Download** `Murmur-3.11.dmg` from [Releases](../../releases).
2. **Drag** `Murmur.app` to your `Applications` folder.
3. **Launch** it. macOS will ask for two permissions:
   - **Microphone** — say yes, that's how it hears you.
   - **Accessibility** — needed to type the transcribed text into other apps.
4. **Wait once** for **whisper-turbo** to download (~1.5 GB from Hugging
   Face). You'll see live progress in the menu:
   ```
   ⬇ Loading turbo: 245 MB / 1,53 GB
   16% · 12,4 MB/s · ETA 1m32s
   ```
5. **Done.** Click into any text field, press **Option+Space**, talk, press
   again. Your words appear at the cursor.

That's it. No accounts, no API keys, nothing leaves your Mac.

## How to use

| Action | How |
|---|---|
| Start recording | `Option+Space` |
| Stop & paste text | `Option+Space` again |
| Cancel without transcribing | `Escape` |
| Free RAM without quitting | menu → **Pause (free RAM)** |
| Switch model (turbo / large) | menu → **Model** |
| Switch microphone | menu → **Microphone** |
| Quit | menu → **Quit Murmur** (`⌘Q`) |

While recording, a small floating capsule appears near the bottom of the screen
with live audio levels. After you stop, an orbital loader spins for 1–3 seconds
while whisper transcribes; then your text is pasted at the cursor and the
overlay disappears.

## Features

- **100% local** — no internet, no API keys, nothing leaves your Mac
- **Fast** — Metal GPU on Apple Silicon, 1–3 seconds for typical phrases
- **Works everywhere** — Mail, Slack, Telegram, Xcode, Terminal, browsers, Notes
- **Two models** — turbo (fast, default) or large (best quality), persisted
  across launches with download progress, speed, and ETA in the menu
- **Pause / Resume** — free 1.5–3 GB of RAM and Metal GPU memory without
  quitting the app
- **Microphone selector** — defaults to built-in mic; doesn't get confused by
  Bluetooth speakers or virtual devices
- **Multi-monitor aware** — overlay always lands on the screen with your cursor
- **Liquid Glass UI** — native macOS Tahoe design, adaptive to dark/light mode,
  with `ultraThinMaterial` fallback on macOS 14–15
- **Auto-delete unused models** *(new in v3.9)* — any model you haven't dictated
  with for **3 days** is deleted from disk on next launch. Pick it later and it
  re-downloads through the same progress UI. Keeps experimental engines from
  silently squatting ~6 GB.
- **Smart paste** — saves your clipboard, pastes text, restores clipboard 0.5s
  later

## Troubleshooting

### Hotkey does nothing

1. Look at your menubar — the Murmur icon should be there. If not, open
   `/Applications/Murmur.app`.
2. Click the icon. If you see `Loading model...` or download progress —
   wait for it to finish.
3. If you see `⏸ Paused — model unloaded` — click **Resume**.
4. If another app is using `Option+Space`, change one of them.

### Recording starts, but nothing gets pasted

Almost always **Accessibility** permission. macOS doesn't always re-prompt:

1. **System Settings → Privacy & Security → Accessibility**
2. Toggle **Murmur** ON. If it isn't in the list, click **+** and add
   `/Applications/Murmur.app`.
3. Quit and relaunch Murmur from the menu.

### Microphone error or no audio detected

1. **System Settings → Privacy & Security → Microphone** — Murmur should be ON.
2. Click the Murmur icon → **Microphone** — make sure the right device is
   selected. The default is the built-in mic.
3. If you have Bluetooth headphones connected and macOS picked them as input
   incorrectly, switch to **Built-in microphone** in the Microphone menu.

### Model is taking too much RAM

Click the Murmur icon → **Pause (free RAM)** to unload the model. The whisper
context is freed (`whisper_free`) — both CPU RAM and Metal GPU buffers go back
to the OS. Click **Resume** to reload (a few seconds for warmup, no re-download).

| Model | RAM (approx) | Where it runs |
|---|---|---|
| turbo | ~1.5 GB | CPU + Metal GPU |
| large | ~3 GB | CPU + Metal GPU |
| parakeet | ~66 MB | Apple Neural Engine (ANE) |

Parakeet is ~25× lighter on memory because Core ML keeps it resident on the
ANE instead of the GPU — pause is rarely needed if you stick with Parakeet.

### I want better transcription quality

- **Russian audio**: try **large** (whisper). Bigger model, ~3 GB on disk,
  3–5 s per phrase, better on accents, names, mixed-language content.
- **Other languages** (English, French, German, …): switch to **parakeet** —
  it auto-detects the language and was trained on multilingual data.

Set in: menu → **Model**. Persists across launches.

### Switching languages

- **Use parakeet** (recommended): switch in menu → **Model → parakeet**. It
  auto-detects across 25 European languages + Japanese + Chinese — no code
  change needed.
- **Or, stick with whisper but change the hardcoded language**:
  1. Open `Sources/Murmur/WhisperEngine.swift`.
  2. Find `let langStr = strdup("ru")` near the bottom of `transcribeRaw`.
  3. Change `"ru"` to `"en"`, `"de"`, `"es"`, etc. (any [whisper.cpp language
     code](https://github.com/ggerganov/whisper.cpp/blob/master/src/whisper.cpp)).
  4. Rebuild: `./build-app.sh`.

  Why hardcode? whisper.cpp 1.8.4 has a bug in automatic language detection
  that returns zero text. Parakeet has its own detector that works.

You can also adjust `params.initial_prompt` to bias whisper toward your style
of punctuation and vocabulary.

### Updating from an older version

Just download the new `.dmg` and drag `Murmur.app` over the existing one in
`/Applications`. macOS replaces the bundle. Your downloaded models, selected
microphone, and chosen model are preserved (they live in `~/Library/Application
Support/Murmur` and `UserDefaults`).

If after update Cmd+V paste stops working, re-grant Accessibility (see above).

## Permissions explained

| Permission | Why it's needed | Where to grant |
|---|---|---|
| **Microphone** | To record your voice | System Settings → Privacy & Security → Microphone |
| **Accessibility** | To paste the transcribed text into the focused field via simulated `Cmd+V` | System Settings → Privacy & Security → Accessibility |

Both are prompted on first launch. If you ever revoke one, just toggle it
back ON in System Settings — no reinstall needed.

## Models

All models download automatically on first selection. Last-used model is
remembered across launches.

| Model | Engine | Size on disk | Working memory | Speed | Languages | When to use |
|---|---|---|---|---|---|---|
| **turbo** *(default)* | whisper.cpp (Metal GPU) | ~1.5 GB | ~1.5 GB | 1–2 s | Russian (hardcoded) | Default for fresh installs. Best transcription quality in our A/B tests on Russian dictation. |
| **parakeet** | FluidAudio / Core ML (ANE) | ~600 MB | **~66 MB** | < 1 s | **25 EU + JP + ZH, auto** | Lightest option. Multilingual, frees the Metal GPU, lowest memory footprint. |
| **whisper-ane** | Argmax WhisperKit / Core ML (ANE) | ~626 MB | ~200 MB | ~1 s | **whisper-large-v3, auto-detect (99+ langs)** | Whisper quality with ANE residency. Useful when you need multilingual + whisper-level accuracy. |
| **large** | whisper.cpp (Metal GPU) | ~3 GB | ~3 GB | 3–5 s | Russian (hardcoded) | Full whisper-large-v3 model. Slower but higher accuracy ceiling than turbo. |

Storage:
- whisper models: `~/Library/Application Support/Murmur/models/` (downloaded
  from [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp))
- parakeet: FluidAudio cache (downloaded from
  [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml))

---

## For developers

### Build from source

**Requires the full Xcode** (not just Command Line Tools — needs the Metal
framework). If `xcode-select -p` points at `/Library/Developer/CommandLineTools`,
fix it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

**Metal Toolchain required.** mlx-swift compiles `default.metallib` from
its kernels, which needs the Metal Toolchain — a separate Xcode component
not installed by default. Run once:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Then build:

```bash
git clone https://github.com/JamesonDeagle/murmur.git
cd murmur
./build-app.sh
open /Applications/Murmur.app
```

`build-app.sh` runs `xcodebuild build -scheme Murmur -configuration Release
ARCHS=arm64`, assembles the `.app` bundle (including SPM resource bundles
like `mlx-swift_Cmlx.bundle` so MLX can find its metallib at runtime),
code-signs with your developer identity (so Accessibility permission
survives rebuilds), and copies into `/Applications/`.

Plain SPM build (no bundle):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
swift test
```

### Architecture

Single executable, ~10 Swift files in `Sources/Murmur/`, statically linked
against whisper.cpp + ggml libs in `lib/`.

```
Option+Space → AppState.toggle()
  → AudioRecorder.start()           [AVAudioEngine, 44.1 kHz mono]
  → ... user speaks ...
Option+Space → AudioRecorder.stop()
  → resample 44.1 k → 16 k, normalize peak to 0.9
  → (any SpeechEngine).transcribe() ─┬─ WhisperEngine  [whisper.cpp + Metal GPU]
                                     └─ ParakeetEngine [FluidAudio + Core ML + ANE]
  → TextPaster.paste()               [NSPasteboard + simulated Cmd+V]
                                     [restores clipboard after 0.5 s]
```

| Component | Role | Threading |
|---|---|---|
| `AppState` | State machine, orchestration, engine swapping | `@MainActor` |
| `AudioRecorder` | AVAudioEngine capture, resample, normalize | Audio thread + `NSLock` |
| `SpeechEngine` (protocol) | `loadModel` / `transcribe` / `cleanup` contract | — |
| `WhisperEngine` | whisper.cpp C API wrapper (turbo / large) | Swift `actor` |
| `ParakeetEngine` | FluidAudio wrapper for Parakeet TDT v3 on ANE | Swift `actor` |
| `HotkeyManager` | Carbon `RegisterEventHotKey` (Option+Space) | Event thread |
| `TextPaster` | `NSPasteboard` + `CGEvent` Cmd+V | `@MainActor` |
| `InputDeviceManager` | CoreAudio input device enumeration | — |
| `WaveformView` / `WaveformOverlay` | Liquid Glass UI + `NSPanel` | `@MainActor` |
| `ProgressDownloader` | `URLSessionDownloadDelegate`, EMA-smoothed speed (whisper only) | Delegate queue |

`AppState.engine: (any SpeechEngine)?` is swapped when the user crosses
engine boundaries (whisper ↔ parakeet). Same-engine variant changes
(turbo ↔ large) reuse the existing `WhisperEngine` actor.

State machine:

```
.loading ──► .idle ◄──► .paused
              │
              ▼ Option+Space
          .recording ──► .transcribing ──► .idle
              │
              ▼ Escape
            .idle
```

### Tech stack

- **Swift 6** + SwiftUI
- **whisper.cpp** — C API, statically linked, Metal GPU
- **CoreAudio** — input device enumeration
- **Carbon Events** — global hotkey registration (still the most reliable way
  on modern macOS for menubar apps without Accessibility-mediated input
  monitoring)
- **Accelerate** — vDSP for audio processing

### Debug

```bash
# Live log (file-based — NSLog/os.log are filtered for menubar apps)
tail -f ~/.murmur-debug.log

# Check downloaded models
ls -lh ~/Library/Application\ Support/Murmur/models/

# Kill running instance + relaunch
pkill -f Murmur.app/Contents/MacOS/Murmur
open /Applications/Murmur.app

# Run with stdout visible
/Applications/Murmur.app/Contents/MacOS/Murmur
```

### Known technical limitations

- **Whisper language hardcoded** — `detect_language=true` + `language="auto"`
  produces zero segments in whisper.cpp 1.8.4. `WhisperEngine` sets
  `language="ru"` explicitly. Switch in `WhisperEngine.swift::transcribeRaw`,
  or simply use Parakeet which has working auto-detection.
- **Apple Silicon only** — Intel Macs are not supported because the build links
  against Metal-accelerated ggml backends.
- **First-launch download is large** — turbo is 1.5 GB, large is 3 GB. You'll
  see live progress in the menu (size, speed, ETA), but if you're on a slow
  connection, expect a wait the first time.

## License

MIT
