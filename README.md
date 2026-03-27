# Murmur

**Type at the speed of thought.** Speak naturally, get perfectly punctuated text — instantly, privately, offline.

Murmur replaces Apple Dictation with OpenAI's Whisper running natively on Apple Silicon. No cloud, no subscription, no data leaves your Mac. Just press **Option+Space**, speak, and your words appear as text.

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Privacy](https://img.shields.io/badge/privacy-100%25%20offline-brightgreen)

## Why Whisper STT?

| | Apple Dictation | Murmur |
|---|---|---|
| **Privacy** | Sends audio to Apple servers | 100% local, never leaves your Mac |
| **Mixed languages** | Struggles with code-switching | Handles naturally (e.g. Russian + English) |
| **Punctuation** | Inconsistent | Always proper capitalization and punctuation |
| **Speed** | Network dependent | ~1 second on Apple Silicon |
| **Cost** | Free | Free and open source |
| **Customization** | None | Custom hotkey, model selection |

## Features

- **100% offline** — all processing happens on your Mac's GPU via Apple MLX
- **~1 second transcription** — Whisper Large V3 Turbo optimized for Metal
- **100+ languages** — automatic detection, mixed-language support out of the box
- **Always punctuated** — proper capitalization, commas, periods on any speech style
- **Live waveform** — animated pill overlay reacts to your voice in real-time
- **Morphing loader** — waveform smoothly transforms into a spinner during processing
- **Customizable hotkey** — change from the menubar, saved across restarts
- **Model selection** — switch between Turbo (fast) and Large (best quality)
- **Native menubar app** — vector icon, all controls in one place
- **Auto-start** — ready when you are, launches silently on login
- **One-command install** — up and running in under 5 minutes

## Quick Start

### Option 1: Download DMG (easiest)

1. Download **[Murmur-Installer.dmg](https://github.com/JamesonDeagle/murmur/releases/latest)** from Releases
2. Open the DMG, double-click **Install Murmur**
3. If macOS blocks it: System Settings > Privacy & Security > click **Open Anyway**
4. Wait ~5 minutes — everything installs automatically

### Option 2: One-line terminal install

```bash
curl -fsSL https://raw.githubusercontent.com/JamesonDeagle/murmur/main/install.sh | bash
```

The installer opens macOS permission dialogs automatically — just toggle them on when prompted. After install, press **Option+Space** and start talking.

## Usage

| Action | Key |
|--------|-----|
| Start / stop recording | **Option+Space** |
| Cancel recording | **Escape** |

Click the waveform icon in the menubar to:
- **Change hotkey** — click the hotkey item, press your new combo
- **Switch model** — Turbo (fast) or Large (best quality)
- **Check daemon status**

## How It Works

```
┌────────────────────────┐         ┌──────────────────────────┐
│   Hammerspoon (Lua)    │  HTTP   │  Python STT Daemon       │
│  • Custom hotkey       │◄───────►│  • Whisper model on GPU  │
│  • Live waveform pill  │ :19876  │  • Microphone recording  │
│  • Morphing loader     │localhost│  • Real-time audio levels│
│  • Menubar controls    │         │  • Auto-start on login   │
└────────────────────────┘         └──────────────────────────┘
```

1. **Option+Space** — recording starts, waveform pill appears at the bottom of your screen
2. **Speak** — bars react to your voice in real-time
3. **Option+Space** — bars fade, pill morphs into a spinner, Whisper transcribes
4. **Text appears** — pasted into whatever app has focus

Everything runs locally over `localhost`. Zero network traffic.

## Models

| Model | Speed | Quality | Size | Best for |
|-------|-------|---------|------|----------|
| **Turbo** (default) | ~1s | Excellent | 1.5 GB | Daily use, fast dictation |
| Large | ~2-3s | Best | 3 GB | Long recordings, difficult audio |

Turbo is installed automatically. Large downloads on first selection from the menubar.

## Requirements

- Mac with **Apple Silicon** (M1 / M2 / M3 / M4)
- macOS Sonoma or later recommended
- ~2 GB free RAM
- ~1.5 GB disk (Turbo model)

## API

The daemon exposes a local HTTP API on `127.0.0.1:19876`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/toggle` | POST | Start/stop recording |
| `/cancel` | POST | Cancel current recording |
| `/status` | GET | Daemon state + active model |
| `/models` | GET | Available models |
| `/model` | POST | Switch model |
| `/levels` | GET | Real-time audio levels (11 bars) |

Build your own integrations — trigger recording from scripts, Shortcuts, or other tools.

## Files

```
~/.whisper-stt/
├── whisper-stt-daemon.py    # Python daemon
├── config.json              # Hotkey + model settings
├── venv/                    # Python virtual environment
└── logs/                    # Daemon logs

~/.hammerspoon/
├── init.lua                 # Hotkey, overlay, menubar
├── waveform.html            # Animated waveform + morphing loader
└── icon.pdf                 # Vector menubar icon (Apple HIG)
```

## Uninstall

```bash
./uninstall.sh
```

## Troubleshooting

<details>
<summary>Hotkey doesn't work</summary>

- System Settings > Keyboard > Dictation > set Shortcut to "Off"
- System Settings > Accessibility > Voice Control > turn off
- Or change the hotkey from the menubar to avoid conflicts
</details>

<details>
<summary>"STT daemon not running" alert</summary>

```bash
curl http://127.0.0.1:19876/status
cat ~/.whisper-stt/logs/whisper-stt.err.log
# Restart:
launchctl unload ~/Library/LaunchAgents/com.whisper.stt-daemon.plist
launchctl load ~/Library/LaunchAgents/com.whisper.stt-daemon.plist
```
</details>

<details>
<summary>Slow first transcription after reboot</summary>

The daemon pre-compiles Metal GPU shaders on startup (~30 seconds). Wait for the warmup to complete — subsequent transcriptions are instant.
</details>

<details>
<summary>Microphone permission</summary>

On first run, macOS will ask for microphone access for Python — allow it in System Settings > Privacy & Security > Microphone.
</details>

## License

MIT — use it, modify it, share it.

---

Built with [OpenAI Whisper](https://github.com/openai/whisper), [Apple MLX](https://github.com/ml-explore/mlx), and [Hammerspoon](https://www.hammerspoon.org/).
