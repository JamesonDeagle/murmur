#!/bin/bash
set -e

echo "Removing Murmur..."

# Stop daemon (may be running via LaunchAgent or Hammerspoon)
launchctl unload "$HOME/Library/LaunchAgents/com.whisper.stt-daemon.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.whisper.stt-daemon.plist"
pkill -f whisper-stt-daemon 2>/dev/null || true

# Remove install directory
rm -rf "$HOME/.whisper-stt"

# Remove Hammerspoon config (only if it's ours)
if grep -q "Murmur" "$HOME/.hammerspoon/init.lua" 2>/dev/null; then
    rm -f "$HOME/.hammerspoon/init.lua"
    rm -f "$HOME/.hammerspoon/waveform.html"
    rm -f "$HOME/.hammerspoon/icon.pdf"
    echo "Hammerspoon config removed"
fi

echo "Done. Hammerspoon can be removed: brew uninstall --cask hammerspoon"
