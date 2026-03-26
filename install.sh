#!/bin/bash
set -e

# Whisper STT — local speech-to-text for macOS (Apple Silicon)
# Cmd+F5: start/stop recording, Esc: cancel
#
# Installs: Hammerspoon, Python venv with mlx-whisper, LaunchAgent
# Runs 100% locally, nothing is sent to the internet

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.whisper-stt"
VENV_DIR="$INSTALL_DIR/venv"
DAEMON_SCRIPT="$INSTALL_DIR/whisper-stt-daemon.py"
PLIST_NAME="com.whisper.stt-daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
LOG_DIR="$INSTALL_DIR/logs"
HS_DIR="$HOME/.hammerspoon"

echo ""
echo -e "${BOLD}  Whisper STT Installer${NC}"
echo -e "  Local speech-to-text for macOS (Apple Silicon)"
echo -e "  Model: whisper-large-v3-turbo (MLX)"
echo -e "  Hotkey: Cmd+F5"
echo ""

# --- Check Apple Silicon ---
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    error "Apple Silicon required (M1/M2/M3/M4). Detected: $ARCH"
fi
info "Apple Silicon: OK ($ARCH)"

# --- Check/install Homebrew ---
if ! command -v brew &>/dev/null; then
    warn "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
info "Homebrew: OK"

# --- Install Hammerspoon ---
if [ ! -d "/Applications/Hammerspoon.app" ]; then
    info "Installing Hammerspoon..."
    brew install --cask hammerspoon
else
    info "Hammerspoon: already installed"
fi

# --- Check Python 3 ---
PYTHON=""
if command -v python3 &>/dev/null; then
    PYTHON="$(command -v python3)"
elif [ -f "/opt/homebrew/bin/python3" ]; then
    PYTHON="/opt/homebrew/bin/python3"
else
    info "Installing Python 3..."
    brew install python@3.11
    PYTHON="/opt/homebrew/bin/python3"
fi
info "Python: $PYTHON"

# --- Create install directory ---
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
info "Install directory: $INSTALL_DIR"

# --- Create venv and install dependencies ---
if [ ! -d "$VENV_DIR" ]; then
    info "Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR"
fi

info "Installing dependencies (mlx-whisper, sounddevice)... This may take a few minutes."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet mlx-whisper sounddevice numpy
info "Dependencies installed"

# --- Download model (warmup) ---
info "Downloading whisper-large-v3-turbo model (~1.5 GB)... This may take a few minutes."
"$VENV_DIR/bin/python3" -c "
import mlx_whisper, numpy as np
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo='mlx-community/whisper-large-v3-turbo')
print('Model downloaded and tested')
"
info "Model ready"

# --- Copy daemon script ---
cp "$SCRIPT_DIR/whisper-stt-daemon.py" "$DAEMON_SCRIPT"
chmod +x "$DAEMON_SCRIPT"
info "Daemon script installed"

# --- Setup Hammerspoon ---
mkdir -p "$HS_DIR"

# Backup existing init.lua
if [ -f "$HS_DIR/init.lua" ]; then
    cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.backup.$(date +%s)"
    warn "Existing init.lua saved as backup"
fi

cp "$SCRIPT_DIR/init.lua" "$HS_DIR/init.lua"
cp "$SCRIPT_DIR/waveform.html" "$HS_DIR/waveform.html"
cp "$SCRIPT_DIR/icon.pdf" "$HS_DIR/icon.pdf"
info "Hammerspoon config installed"

# --- Create LaunchAgent ---
# Unload existing if present
launchctl unload "$PLIST_PATH" 2>/dev/null || true

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>Comment</key>
    <string>Local Whisper STT daemon with pre-loaded MLX model</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProgramArguments</key>
    <array>
      <string>$VENV_DIR/bin/python3</string>
      <string>$DAEMON_SCRIPT</string>
    </array>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/whisper-stt.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/whisper-stt.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>$HOME</string>
      <key>PATH</key>
      <string>$VENV_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
  </dict>
</plist>
PLIST

info "LaunchAgent created"

# --- Disable Apple Dictation shortcut ---
defaults write com.apple.HIToolbox AppleDictationAutoEnable -int 0
# Disable VoiceOver on Cmd+F5
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 59 '{ enabled = 0; value = { parameters = (65535, 96, 1048576); type = standard; }; }'
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
info "System shortcuts updated"

# --- Start daemon ---
launchctl load "$PLIST_PATH"
info "Daemon started"

# Wait for model warmup
echo -ne "${GREEN}[+]${NC} Waiting for model warmup..."
for i in $(seq 1 30); do
    STATUS=$(curl -s http://127.0.0.1:19876/status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q '"idle"'; then
        echo -e " ${GREEN}OK${NC}"
        break
    fi
    echo -n "."
    sleep 1
done

# --- Launch Hammerspoon ---
open -a Hammerspoon
info "Hammerspoon launched"

echo ""
echo -e "${BOLD}  Installation complete!${NC}"
echo ""
echo -e "  ${BOLD}Usage:${NC}"
echo -e "    Cmd+F5  — start/stop recording"
echo -e "    Escape  — cancel recording"
echo -e "    Menubar W:turbo — switch models"
echo ""
echo -e "  ${BOLD}Manual steps required:${NC}"
echo -e "    1. Hammerspoon will ask for Accessibility permission — allow it"
echo -e "    2. System Settings > Keyboard > Dictation > turn OFF"
echo -e "       Change Shortcut to \"Off\" or \"Press Control Twice\""
echo -e "    3. Hammerspoon menubar (hammer icon) > Reload Config"
echo ""
echo -e "  ${BOLD}Verify:${NC}"
echo -e "    curl http://127.0.0.1:19876/status"
echo ""
echo -e "  ${BOLD}Logs:${NC} $LOG_DIR/"
echo ""
