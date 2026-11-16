#!/bin/bash
# Removes PrintDeck Bridge completely
GUI="gui/$(id -u)"
launchctl bootout "$GUI" "$HOME/Library/LaunchAgents/com.printdeck.updater.plist" 2>/dev/null
launchctl bootout "$GUI" "$HOME/Library/LaunchAgents/com.printdeck.bridge.plist" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.printdeck.updater.plist" "$HOME/Library/LaunchAgents/com.printdeck.bridge.plist"
rm -rf "$HOME/Applications/PrintDeck Bridge.app" "$HOME/Library/Application Support/PrintDeck"
security delete-certificate -c "PrintDeck Signing" >/dev/null 2>&1
echo "PrintDeck Bridge removed."

pkill -f "Application Support/PrintDeck/go2rtc" 2>/dev/null
