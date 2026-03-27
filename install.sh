#!/bin/bash
set -e

# Murmur — local speech-to-text for macOS (Apple Silicon)
# Option+Space: start/stop recording, Esc: cancel
#
# Installs: Hammerspoon, Python venv with mlx-whisper
# Hammerspoon launches the daemon and inherits mic permission
# Runs 100% locally, nothing is sent to the internet
#
# Supports both: ./install.sh  AND  curl ... | bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# read from real terminal even when piped via curl | bash
prompt_user() {
    echo ""
    echo -e "  ${YELLOW}>>> $1${NC}"
    echo -e "  ${YELLOW}    Press Enter when done...${NC}"
    read -r < /dev/tty
}

INSTALL_DIR="$HOME/.whisper-stt"
VENV_DIR="$INSTALL_DIR/venv"
DAEMON_SCRIPT="$INSTALL_DIR/whisper-stt-daemon.py"
LOG_DIR="$INSTALL_DIR/logs"
HS_DIR="$HOME/.hammerspoon"
REPO_URL="https://github.com/JamesonDeagle/murmur.git"

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

# --- Determine source directory (local clone or curl pipe) ---
SCRIPT_DIR=""
if [ -f "$(dirname "$0")/whisper-stt-daemon.py" ] 2>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    info "Installing from local directory"
else
    # Running via curl | bash — need to clone repo first
    info "Downloading Murmur..."
    TMPDIR_MURMUR=$(mktemp -d)
    if command -v git &>/dev/null; then
        git clone --depth 1 "$REPO_URL" "$TMPDIR_MURMUR/murmur" 2>/dev/null
    else
        # No git — download tarball
        curl -fsSL "https://github.com/JamesonDeagle/murmur/archive/refs/heads/main.tar.gz" \
            | tar xz -C "$TMPDIR_MURMUR"
        mv "$TMPDIR_MURMUR/murmur-main" "$TMPDIR_MURMUR/murmur"
    fi
    SCRIPT_DIR="$TMPDIR_MURMUR/murmur"
    info "Downloaded to temp directory"
fi

# --- Check/install Homebrew ---
if ! command -v brew &>/dev/null; then
    warn "Homebrew not found. Installing..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
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

# --- Check Python 3 with venv support ---
PYTHON=""
if command -v python3 &>/dev/null; then
    # Verify venv module works
    if python3 -c "import venv" 2>/dev/null; then
        PYTHON="$(command -v python3)"
    fi
fi
if [ -z "$PYTHON" ]; then
    info "Installing Python 3..."
    brew install python@3.11
    PYTHON="/opt/homebrew/bin/python3"
fi
info "Python: $PYTHON"

# --- Create install directory ---
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
info "Install directory: $INSTALL_DIR"

# --- Create venv and install dependencies ---
if [ ! -d "$VENV_DIR" ] || [ ! -f "$VENV_DIR/bin/python3" ]; then
    info "Creating virtual environment..."
    rm -rf "$VENV_DIR"
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

# --- Copy project files ---
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

# Backup existing init.lua (only if it's not already Murmur)
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
prompt_user "Add Hammerspoon to Accessibility and click the toggle ON"

# Microphone — Hammerspoon needs this for the daemon it spawns
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
prompt_user "Click '+', select /Applications/Hammerspoon.app, toggle ON"

info "Permissions configured"

# --- Launch Hammerspoon (it will start the daemon automatically) ---
osascript -e 'tell application "Hammerspoon" to quit' 2>/dev/null || true
sleep 1
open -a Hammerspoon
info "Hammerspoon launched"

# Wait for daemon to come up (Hammerspoon spawns it)
echo -ne "${GREEN}[+]${NC} Waiting for daemon startup..."
DAEMON_UP=false
for i in $(seq 1 45); do
    STATUS=$(curl -s http://127.0.0.1:19876/status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q '"idle"\|"loading"'; then
        echo -e " ${GREEN}OK${NC}"
        DAEMON_UP=true
        break
    fi
    echo -n "."
    sleep 1
done
if [ "$DAEMON_UP" = false ]; then
    warn "Daemon did not start. Check logs: $LOG_DIR/whisper-stt.err.log"
    warn "Try: Hammerspoon menubar > Reload Config"
fi

# Wait for model warmup
echo -ne "${GREEN}[+]${NC} Waiting for model warmup..."
MODEL_READY=false
for i in $(seq 1 90); do
    STATUS=$(curl -s http://127.0.0.1:19876/status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q '"idle"'; then
        echo -e " ${GREEN}OK${NC}"
        MODEL_READY=true
        break
    fi
    echo -n "."
    sleep 1
done
if [ "$MODEL_READY" = false ]; then
    warn "Model warmup taking longer than expected. It will finish in the background."
fi

# Cleanup temp directory if used
if [ -n "${TMPDIR_MURMUR:-}" ]; then
    rm -rf "$TMPDIR_MURMUR"
fi

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
