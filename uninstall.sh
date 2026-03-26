#!/bin/bash
set -e

echo "Removing Murmur..."

# Stop daemon
launchctl unload "$HOME/Library/LaunchAgents/com.whisper.stt-daemon.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.whisper.stt-daemon.plist"

# Remove install directory
rm -rf "$HOME/.whisper-stt"

# Remove Hammerspoon config (only if it's ours)
if grep -q "Whisper STT" "$HOME/.hammerspoon/init.lua" 2>/dev/null; then
    rm -f "$HOME/.hammerspoon/init.lua"
    rm -f "$HOME/.hammerspoon/waveform.html"
    echo "Hammerspoon config removed"
fi

echo "Готово. Hammerspoon можно удалить: brew uninstall --cask hammerspoon"
