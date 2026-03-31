# Murmur 🐱

Native macOS menubar app for speech-to-text. Runs **fully local** on Apple Silicon via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration. Single `.app` file, zero dependencies, drag-to-install.

**Option+Space → speak → Option+Space → text pastes into any field.**

<img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+"> <img src="https://img.shields.io/badge/Apple_Silicon-M1%2FM2%2FM3%2FM4-green" alt="Apple Silicon"> <img src="https://img.shields.io/badge/UI-Liquid_Glass-purple" alt="Liquid Glass">

## Features

- **100% local** — no internet, no API keys, no data leaves your Mac
- **Metal GPU** — fast transcription on Apple Silicon (1-2s for typical phrases)
- **Liquid Glass UI** — native macOS Tahoe design with adaptive dark/light theme
- **Microphone selector** — choose input device, defaults to built-in mic (no Bluetooth speaker issues)
- **Orbital loader** — custom animated transcription indicator
- **Model choice** — turbo (fast) or large (best quality)
- **Global hotkey** — Option+Space works in any app, any Space
- **Smart paste** — saves clipboard, pastes text, restores clipboard

## Install

### From DMG
1. Download `Murmur-3.1.dmg` from [Releases](../../releases)
2. Drag `Murmur.app` to `/Applications`
3. Launch — grant Microphone and Accessibility permissions when prompted
4. Done! Use **Option+Space** to start

### Build from Source
```bash
git clone https://github.com/JamesonDeagle/Murmur.git
cd Murmur
./build-app.sh
open /Applications/Murmur.app
```

**Requirements:** Xcode (full, not just CLI tools) for Metal framework.

## How It Works

```
Option+Space → record audio (AVAudioEngine, 44.1kHz)
Option+Space → stop → resample to 16kHz → normalize
             → whisper.cpp transcribe (Metal GPU)
             → paste text via simulated Cmd+V
             → restore clipboard
```

### State Machine
```
.loading → .idle → .recording → .transcribing → .idle
                     ↓ Escape
                   .idle
```

## Architecture

| Component | Role | Thread |
|-----------|------|--------|
| `AppState` | State machine, orchestration | @MainActor |
| `AudioRecorder` | AVAudioEngine capture, resample, normalize | Audio thread + NSLock |
| `TranscriptionEngine` | whisper.cpp C API wrapper | Swift actor |
| `HotkeyManager` | Carbon global hotkey (Option+Space) | Event thread |
| `TextPaster` | Clipboard + CGEvent Cmd+V simulation | Main |
| `InputDeviceManager` | CoreAudio device enumeration | — |
| `WaveformView` | Liquid Glass UI + OrbitalLoader | @MainActor |
| `WaveformOverlay` | NSPanel floating window | @MainActor |

## Models

Downloaded automatically on first launch (~1.5 GB for turbo):

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| turbo | ~1.5 GB | ~1-2s | Good |
| large | ~3 GB | ~3-5s | Best |

Source: [ggerganov/whisper.cpp on HuggingFace](https://huggingface.co/ggerganov/whisper.cpp)

## UI

### macOS Tahoe (26+)
Uses native **Liquid Glass** (`.glassEffect()`) with adaptive `Color.primary` elements — black bars/dots on light backgrounds, white on dark.

### macOS 14-15
Falls back to `.ultraThinMaterial` with equivalent styling.

### Recording
Floating capsule with 11 animated waveform bars responding to mic input in real-time.

### Transcribing
Orbital loader — 8 dots on outer ring + 5 counter-rotating inner dots + pulsing center glow, all inside a glass circle.

## Permissions

Murmur needs two permissions (prompted automatically on first launch):

| Permission | Why |
|-----------|-----|
| **Microphone** | Audio capture for transcription |
| **Accessibility** | Simulate Cmd+V to paste text |

## Debug

```bash
# Live log
tail -f ~/.murmur-debug.log

# Check models
ls ~/Library/Application\ Support/Murmur/models/

# Kill & relaunch
pkill -f Murmur.app/Contents/MacOS/Murmur
open /Applications/Murmur.app
```

## Known Limitations

- Language hardcoded to Russian (whisper.cpp `detect_language` bug workaround)
- Accessibility permission may reset after rebuilding from source (code signing mitigates this)

## Tech Stack

- **Swift 6** + SwiftUI
- **whisper.cpp** — C API, static linking, Metal GPU
- **CoreAudio** — input device enumeration
- **Carbon Events** — global hotkey registration
- **Accelerate** — vDSP for audio processing

## License

MIT
