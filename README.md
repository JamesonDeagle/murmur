# Whisper STT for macOS

Local speech-to-text for macOS using [OpenAI Whisper](https://github.com/openai/whisper) optimized for Apple Silicon via [MLX](https://github.com/ml-explore/mlx).

Replaces Apple Dictation with a faster, more accurate, fully offline alternative. Supports 100+ languages with automatic detection, handles mixed-language speech naturally.

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Fully local** — nothing is sent to the internet, all processing on your Mac
- **Apple Silicon native** — Metal GPU via Apple MLX framework
- **Fast** — ~1 second transcription with the turbo model
- **Proper punctuation** — capitalization, commas, periods always preserved
- **Multi-language** — auto-detection, handles mixed languages (e.g. Russian + English)
- **Live waveform** — animated pill reacts to your voice in real-time
- **Morphing loader** — pill smoothly transforms into a spinning loader during transcription
- **Customizable hotkey** — change the trigger key from the menubar (persisted to config)
- **Model switching** — turbo / medium / large from the menubar
- **Menubar app** — single icon with all controls, no clutter
- **Auto-start** — daemon launches on login via LaunchAgent
- **Accidental press protection** — recordings < 1 second auto-cancel
- **Instant startup** — pre-warmed webview and HTTP connections, no first-use lag

## How It Works

```
┌────────────────────────┐         ┌──────────────────────────┐
│   Hammerspoon (Lua)    │  HTTP   │  Python STT Daemon       │
│  • Customizable hotkey │◄───────►│  • mlx_whisper preloaded │
│  • Live waveform pill  │ :19876  │  • sounddevice recording │
│  • Morphing loader     │localhost│  • Real-time audio levels│
│  • Menubar controls    │         │  • Auto-start on login   │
└────────────────────────┘         └──────────────────────────┘
```

1. Press **Cmd+F5** (or your custom hotkey) — recording starts, waveform pill appears at the bottom of the screen
2. Speak (any language) — bars react to your voice in real-time
3. Press **Cmd+F5** again — bars fade out, pill morphs into a spinning loader, Whisper transcribes, text is pasted
4. Press **Escape** to cancel

## Requirements

- macOS on **Apple Silicon** (M1/M2/M3/M4)
- ~2 GB free RAM (for the turbo model)
- ~1.5 GB disk space (for model weights)

## Installation

### One-command install

```bash
git clone https://github.com/JamesonDeagle/whisper-stt.git
cd whisper-stt
chmod +x install.sh
./install.sh
```

The installer will:
1. Install [Hammerspoon](https://www.hammerspoon.org/) (if not present)
2. Create a Python virtual environment with `mlx-whisper` and `sounddevice`
3. Download the Whisper Large V3 Turbo model (~1.5 GB)
4. Set up Hammerspoon config with waveform overlay and menubar icon
5. Create and start a LaunchAgent for the daemon
6. Disable VoiceOver Cmd+F5 shortcut

### Manual steps after install

1. **Hammerspoon** will ask for Accessibility permission — allow it in System Settings > Privacy & Security > Accessibility
2. **Disable Apple Dictation shortcut**: System Settings > Keyboard > Dictation > change Shortcut to "Off" or "Press Control Twice"
3. Click the menubar icon > **Reload Config**

### Verify

```bash
curl http://127.0.0.1:19876/status
# {"status": "idle", "model": "turbo"}
```

## Usage

| Action | Default Key |
|--------|-------------|
| Start/stop recording | **Cmd+F5** |
| Cancel recording | **Escape** |

### Menubar Controls

Click the waveform icon in the menubar:

- **Change hotkey** — click the hotkey item, then press your new combo
- **Model** — switch between turbo / medium / large
- **Reload Config** — reload Hammerspoon config
- **Daemon Status** — check if the daemon is running

### Custom Hotkey

Click the hotkey item in the menubar menu (e.g. "Cmd+F5 — record / stop"), then press your desired key combination. The new hotkey is saved to `~/.whisper-stt/config.json` and persists across restarts.

## Models

Switch models from the menubar. Models are downloaded on first use.

| Model | Parameters | Speed | Quality | Size |
|-------|-----------|-------|---------|------|
| **turbo** (default) | 809M | ~1s | Excellent | 1.5 GB |
| large | 1.5B | ~2-3s | Best | 3 GB |

Turbo is installed by default. It's a distilled version of large-v3 with 95-98% of its quality at 2-3x speed — recommended for most use cases. Large downloads on first selection from the menubar.

## API

The daemon runs a local HTTP server on `127.0.0.1:19876`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/toggle` | POST | Start/stop recording. Returns `{"status": "done", "text": "..."}` on stop |
| `/cancel` | POST | Cancel current recording |
| `/status` | GET | Current state + active model |
| `/models` | GET | List available models |
| `/model` | POST | Switch model: `{"model": "turbo"}` |
| `/levels` | GET | Real-time audio levels (11 bars, 0.0-1.0) |

## Uninstall

```bash
./uninstall.sh
```

Removes the daemon, LaunchAgent, virtual environment, and Hammerspoon config. Hammerspoon itself: `brew uninstall --cask hammerspoon`.

## Files

```
~/.whisper-stt/
├── whisper-stt-daemon.py    # Python daemon
├── config.json              # Hotkey settings
├── venv/                    # Virtual environment
└── logs/                    # Daemon logs

~/.hammerspoon/
├── init.lua                 # Hotkey, overlay, menubar
├── waveform.html            # Animated waveform + loader
└── icon.pdf                 # Vector menubar icon (22x22pt, Apple HIG)

~/Library/LaunchAgents/
└── com.whisper.stt-daemon.plist
```

## Troubleshooting

**Hotkey triggers VoiceOver or Apple Dictation**
- System Settings > Keyboard > Dictation > set Shortcut to "Off"
- System Settings > Accessibility > Voice Control > turn off
- Or change the hotkey from the menubar to avoid conflicts

**"STT daemon not running" alert**
- Check: `curl http://127.0.0.1:19876/status`
- Logs: `cat ~/.whisper-stt/logs/whisper-stt.err.log`
- Restart: `launchctl unload ~/Library/LaunchAgents/com.whisper.stt-daemon.plist && launchctl load ~/Library/LaunchAgents/com.whisper.stt-daemon.plist`

**Slow first transcription after restart**
- The daemon warms up Metal GPU shaders on start (~30 sec). Wait for warmup to complete before using.

**No text appears after recording**
- Make sure the cursor is in a text field
- Check daemon logs for transcription output

**Microphone permission**
- On first run, macOS will ask for mic permission for Python — allow it

## License

MIT
