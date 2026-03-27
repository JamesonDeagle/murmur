#!/bin/bash
set -e

# Murmur — local speech-to-text for macOS (Apple Silicon)
# Option+Space: start/stop recording, Esc: cancel
#
# Installs: Hammerspoon, Python venv with mlx-whisper
# Hammerspoon launches the daemon and inherits mic permission
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
LOG_DIR="$INSTALL_DIR/logs"
HS_DIR="$HOME/.hammerspoon"

echo ""
echo -e "${BOLD}  Murmur Installer${NC}"
echo -e "  Local speech-to-text for macOS (Apple Silicon)"
echo -e "  Model: Whisper Large V3 Turbo (MLX)"
echo -e "  Hotkey: Option+Space"
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

# --- Remove old LaunchAgent if present (from previous versions) ---
OLD_PLIST="$HOME/Library/LaunchAgents/com.whisper.stt-daemon.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    info "Removed old LaunchAgent (daemon now runs via Hammerspoon)"
fi

# --- Setup Hammerspoon ---
mkdir -p "$HS_DIR"

# Backup existing init.lua
if [ -f "$HS_DIR/init.lua" ]; then
    if ! grep -q "Murmur" "$HS_DIR/init.lua" 2>/dev/null; then
        cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.backup.$(date +%s)"
        warn "Existing init.lua saved as backup"
    fi
fi

cp "$SCRIPT_DIR/init.lua" "$HS_DIR/init.lua"
cp "$SCRIPT_DIR/waveform.html" "$HS_DIR/waveform.html"
cp "$SCRIPT_DIR/icon.pdf" "$HS_DIR/icon.pdf"
info "Hammerspoon config installed"

# --- Disable Apple Dictation shortcut ---
defaults write com.apple.HIToolbox AppleDictationAutoEnable -int 0
info "System shortcuts checked"

# --- Open permissions that macOS requires ---
info "Opening macOS permissions..."

# Accessibility — Hammerspoon needs this for hotkeys
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
echo ""
echo -e "  ${YELLOW}>>> Add Hammerspoon to Accessibility and click the toggle ON${NC}"
echo -e "  ${YELLOW}    Press Enter when done...${NC}"
read -r

# Microphone — Hammerspoon needs this for the daemon it spawns
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
echo ""
echo -e "  ${YELLOW}>>> Click '+', select /Applications/Hammerspoon.app, toggle ON${NC}"
echo -e "  ${YELLOW}    Press Enter when done...${NC}"
read -r

info "Permissions configured"

# --- Launch Hammerspoon (it will start the daemon automatically) ---
osascript -e 'tell application "Hammerspoon" to quit' 2>/dev/null || true
sleep 1
open -a Hammerspoon
info "Hammerspoon launched"

# Wait for daemon to come up (Hammerspoon spawns it)
echo -ne "${GREEN}[+]${NC} Waiting for daemon startup..."
for i in $(seq 1 45); do
    STATUS=$(curl -s http://127.0.0.1:19876/status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q '"idle"\|"loading"'; then
        echo -e " ${GREEN}OK${NC}"
        break
    fi
    echo -n "."
    sleep 1
done

# Wait for model warmup
echo -ne "${GREEN}[+]${NC} Waiting for model warmup..."
for i in $(seq 1 60); do
    STATUS=$(curl -s http://127.0.0.1:19876/status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q '"idle"'; then
        echo -e " ${GREEN}OK${NC}"
        break
    fi
    echo -n "."
    sleep 1
done

echo ""
echo -e "${BOLD}  Murmur installed!${NC}"
echo ""
echo -e "  ${BOLD}Usage:${NC}"
echo -e "    Option+Space  — start/stop recording"
echo -e "    Escape  — cancel recording"
echo -e "    Menubar icon — switch models, change hotkey"
echo ""
echo -e "  ${BOLD}Verify:${NC}"
echo -e "    curl http://127.0.0.1:19876/status"
echo ""
echo -e "  ${BOLD}Logs:${NC} $LOG_DIR/"
echo ""
