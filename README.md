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

> **Two whisper models, you pick in the Model menu.**
> - **turbo** *(default, recommended)* — whisper-large-v3-turbo via whisper.cpp + Metal GPU. **Best transcription quality** based on our A/B tests on Russian dictation. ~1.5 GB, 1–2s per phrase. Language follows your system locale; switch anytime in menu → Language.
> - **large** — whisper.cpp + Metal, full large model (not turbo). ~3 GB, higher accuracy ceiling, slower.

## Quick start (60 seconds)

1. **Download** `Murmur-3.24.dmg` from [Releases](../../releases).
2. **Drag** `Murmur.app` to your `Applications` folder.
3. **First-launch step** *(important — macOS will block a double-click)*:
   - Open Finder → `Applications`.
   - **Right-click** (or Control-click) on `Murmur.app`.
   - Choose **Open** from the context menu.
   - macOS shows a dialog: *"macOS cannot verify the developer of Murmur."*
   - Click **Open** again. Done — macOS remembers your choice and from now
     on you can launch Murmur normally.

   <details>
   <summary>Why this extra step?</summary>

   Murmur is signed ad-hoc (no paid Apple Developer ID — this is a free
   open-source project). Gatekeeper requires a one-time explicit user
   action to launch any ad-hoc-signed app. Double-clicking shows a
   scary "cannot be opened" alert with no Open button; only the
   Right-click → Open path unlocks the override. After that one
   confirmation, every subsequent launch is silent.

   The same flow works for any other open-source macOS app shipped
   outside the App Store.
   </details>

4. **Grant permissions.** macOS will ask for two:
   - **Microphone** — say yes, that's how it hears you.
   - **Accessibility** — needed to type the transcribed text into other apps.
5. **Wait once** for **whisper-turbo** to download (~1.5 GB from Hugging
   Face). You'll see live progress in the menu:
   ```
   ⬇ Loading turbo: 245 MB / 1,53 GB
   16% · 12,4 MB/s · ETA 1m32s
   ```
6. **Done.** Click into any text field, press **Option+Space**, talk, press
   again. Your words appear at the cursor.

That's it. No accounts, no API keys, nothing leaves your Mac.

### If macOS says the app is damaged

If you see *"Murmur is damaged and can't be opened"* (without the
Right-click → Open path even being offered), it's the
`com.apple.quarantine` extended attribute your browser stuck on the DMG.
Strip it once:

```bash
sudo xattr -rd com.apple.quarantine /Applications/Murmur.app
```

Then launch normally. This isn't a bug in Murmur — it's macOS being
extra cautious with downloads from new domains/browsers, and the same
fix applies to most open-source Mac apps.

## How to use

| Action | How |
|---|---|
| Start recording | `Option+Space` |
| Stop & paste text | `Option+Space` again |
| Cancel without transcribing | `Escape` |
| Free RAM without quitting | menu → **Pause (free RAM)** |
| Switch model (turbo / large) | menu → **Model** |
| Switch language (8 languages) | menu → **Language** |
| Switch microphone | menu → **Microphone** |
| Change the shortcut | menu → **Shortcut** |
| Quit | menu → **Quit Murmur** (`⌘Q`) |

While recording, an **ambient light glow** wraps the perimeter of the
MacBook notch — pink, white, yellow, cyan flowing left-to-right along the
contour. The flow speed and the glow's brightness both scale with how loud
you talk: paused = a slow shimmer barely-there, mid-sentence = a brisk
stream, shouting = a bright wide halo. On screens without a notch —
external monitors, pre-2021 MacBooks — a black **Dynamic Island** slides
out of the top edge for the duration of the dictation, and the same glow
wraps around it.

When you stop, the palette **morphs smoothly** to blue-and-white
(`easeInOut`, 0.55s) and the flow settles to a steady moderate pace while
whisper transcribes (typically 1–3 seconds). Your text is pasted at the
cursor and the glow fades out.

## Features

- **100% local** — no internet, no API keys, nothing leaves your Mac
- **Fast** — Metal GPU on Apple Silicon, 1–3 seconds for typical phrases
- **Works everywhere** — Mail, Slack, Telegram, Xcode, Terminal, browsers, Notes
- **Two models** — turbo (fast, default) or large (best quality), persisted
  across launches with download progress, speed, and ETA in the menu
- **Configurable shortcut** — ⌥Space by default; pick ⌘⇧Space, ⌃⇧Space, or
  ⌘⇧D in menu → **Shortcut**; the choice persists across launches. On macOS
  builds that reject Option-only hotkeys (FB15168205) Murmur silently falls
  back to ⌘⇧Space
- **Pause / Resume** — free 1.5–3 GB of RAM and Metal GPU memory without
  quitting the app
- **Microphone selector** — defaults to built-in mic; doesn't get confused by
  Bluetooth speakers or virtual devices
- **Multi-monitor aware** — overlay always lands on the screen with your cursor
- **Dynamic Island on notch-less screens** *(new in v3.24)* — on external
  monitors and pre-2021 MacBooks a black island (185 pt, sized to the menu
  bar, with the real notch's concave top-corner flares) slides out of the
  top edge while you dictate, and the same morphing glow wraps its contour.
  Appears only during dictation — no permanent fake notch on your monitor
- **Siri-grade morphing glow around the notch** *(new in v3.23)* — a
  Metal-shader colour field (domain-warped fBM) renders organically
  morphing light blobs along the notch contour: a continuous glowing
  ribbon at rest, blooming blobs and fusing streams as you speak. Voice
  drives three channels — flow speed, blob size and brightness — on
  smooth asymmetric envelopes (fast bloom, slow decay). Light-physics
  colour mixing: overlapping blobs brighten instead of muddying, dark
  mixes can't happen by construction. Smooth palette morph to blue/ice
  while transcribing. Falls back to the v3.21 flowing gradient if the
  shader is unavailable
- **Auto-delete unused models** *(new in v3.9)* — any model you haven't dictated
  with for **3 days** is deleted from disk on next launch. Pick it later and it
  re-downloads through the same progress UI. Keeps an unused large model from
  silently squatting ~3 GB.
- **Paste + clipboard fallback** *(v3.12)* — Murmur puts the transcribed text
  on the clipboard and simulates Cmd+V. If you forgot to click into a text
  field first, the paste silently fails, but the text stays on the clipboard
  so you can paste it manually wherever you actually wanted it.

## Troubleshooting

### Hotkey does nothing

1. Look at your menubar — the Murmur icon should be there. If not, open
   `/Applications/Murmur.app`.
2. Click the icon. If you see `Loading model...` or download progress —
   wait for it to finish.
3. If you see `⏸ Paused — model unloaded` — click **Resume**.
4. If another app is using `Option+Space`, change one of them — or pick a
   different combo in menu → **Shortcut**.

### Recording starts, but nothing gets pasted

Almost always the **post-events / Accessibility** permission Murmur needs to
type the text into other apps via simulated Cmd+V. macOS shows the consent
prompt **once** — if it was dismissed (or never appeared, which happens with
ad-hoc-signed apps), the system silently denies forever until you enable it
manually. When the permission is missing, the Murmur menu shows a warning
item — **"No paste permission — open System Settings"** — click it, or go
manually:

1. **System Settings → Privacy & Security → Accessibility** (on App Store
   builds this may appear under **Input Monitoring**).
2. Toggle **Murmur** ON. If it isn't in the list, click **+** and add
   `/Applications/Murmur.app`.
3. Quit and relaunch Murmur from the menu.

Either way, the transcribed text is always left on the clipboard, so you can
paste it manually with Cmd+V if the automatic paste didn't land. That's also
the quick diagnosis: dictate, then press Cmd+V — if your words paste, whisper
works fine and only this permission is missing.

### Escape doesn't cancel the recording

Same permission as above. The global Escape listener only receives keystrokes
when Murmur is trusted in **Accessibility** — without it, macOS feeds Escape
to the frontmost app only and Murmur never sees it. Grant the permission (see
the previous section) and Escape cancel starts working together with paste.

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

### I want better transcription quality

- **Russian audio**: try **large** (whisper). Bigger model, ~3 GB on disk,
  3–5 s per phrase, better on accents, names, mixed-language content.

Set in: menu → **Model**. Persists across launches.

### Switching languages

Murmur is hardcoded to Russian. To change it:

  1. Open `Sources/Murmur/WhisperEngine.swift`.
  2. Find `let langStr = strdup("ru")` near the bottom of `transcribeRaw`.
  3. Change `"ru"` to `"en"`, `"de"`, `"es"`, etc. (any [whisper.cpp language
     code](https://github.com/ggerganov/whisper.cpp/blob/master/src/whisper.cpp)).
  4. Rebuild: `./build-app.sh`.

  Why hardcode? whisper.cpp 1.8.4 has a bug in automatic language detection
  that returns zero text, so the language has to be set explicitly.

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
| **large** | whisper.cpp (Metal GPU) | ~3 GB | ~3 GB | 3–5 s | Russian (hardcoded) | Full whisper-large-v3 model. Slower but higher accuracy ceiling than turbo. |

Storage:
- whisper models: `~/Library/Application Support/Murmur/models/` (downloaded
  from [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp))

---

## For developers

### Build from source

**Requires the full Xcode** (not just Command Line Tools — needs the Metal
framework). If `xcode-select -p` points at `/Library/Developer/CommandLineTools`,
fix it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

Build:

```bash
git clone https://github.com/JamesonDeagle/murmur.git
cd murmur
./build-app.sh
open /Applications/Murmur.app
```

`build-app.sh` runs `swift build -c release`, assembles the `.app` bundle
(binary + `Info.plist` + icon + `PrivacyInfo.xcprivacy` + `LICENSE` +
`THIRD-PARTY-LICENSES.md`), code-signs with your developer identity (so the
paste permission survives rebuilds), and copies into `/Applications/`.

Plain SPM build (no bundle):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
swift test
```

For a Mac App Store build (3rd Party Mac Developer certificates +
entitlements + `.pkg`), use `./build-mas.sh` instead.

### Architecture

Single executable, ~10 Swift files in `Sources/Murmur/`, statically linked
against whisper.cpp + ggml libs in `lib/`.

```
Option+Space → AppState.toggle()
  → AudioRecorder.start()           [AVAudioEngine, 44.1 kHz mono]
  → ... user speaks ...
Option+Space → AudioRecorder.stop()
  → resample 44.1 k → 16 k, normalize peak to 0.9
  → (any SpeechEngine).transcribe() ── WhisperEngine [whisper.cpp + Metal GPU]
  → TextPaster.paste()               [NSPasteboard + simulated Cmd+V]
                                     [text stays on clipboard for manual paste]
```

| Component | Role | Threading |
|---|---|---|
| `AppState` | State machine, orchestration, engine swapping | `@MainActor` |
| `AudioRecorder` | AVAudioEngine capture, resample, normalize | Audio thread + `NSLock` |
| `SpeechEngine` (protocol) | `loadModel` / `transcribe` / `cleanup` contract | — |
| `WhisperEngine` | whisper.cpp C API wrapper (turbo / large) | Swift `actor` |
| `HotkeyManager` | Carbon `RegisterEventHotKey` (configurable, default ⌥Space, auto-fallback ⌘⇧Space) | Event thread |
| `TextPaster` | `NSPasteboard` + `CGEvent` Cmd+V (gated on `CGPreflightPostEventAccess`) | `@MainActor` |
| `InputDeviceManager` | CoreAudio input device enumeration | — |
| `WaveformView` / `WaveformOverlay` | Liquid Glass UI + `NSPanel` | `@MainActor` |
| `ProgressDownloader` | `URLSessionDownloadDelegate`, EMA-smoothed speed | Delegate queue |

`AppState.engine: (any SpeechEngine)?` is held behind a `SpeechEngine`
protocol + `EngineKind` enum so re-introducing extra backends later stays an
additive change. Today only `WhisperEngine` ships; turbo ↔ large reuse the
same actor.

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
  `language="ru"` explicitly. Switch in `WhisperEngine.swift::transcribeRaw`.
- **Apple Silicon only** — Intel Macs are not supported because the build links
  against Metal-accelerated ggml backends.
- **First-launch download is large** — turbo is 1.5 GB, large is 3 GB. You'll
  see live progress in the menu (size, speed, ETA), but if you're on a slow
  connection, expect a wait the first time.

## License

MIT
