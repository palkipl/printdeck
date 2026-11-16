# PrintDeck

Full-screen dashboard for a **Creality K2 Combo** and an **xTool O1 Omni**.

- **Raspberry Pi** (`pi/`): web server + full-screen app on boot. Shows the K2's live camera, print thumbnail, progress, layers, ETA, temps, fans, speed mode, LED and CFS filament, plus the Omni panel.
- **Mac** (`mac/`): *PrintDeck Bridge*, a menu-bar app that starts at login, streams the xTool Studio window, checks the Omni is plugged in over USB, and is found by the Pi automatically.

The Pi checks this repo **every 2 seconds** and reboots after installing an update; the Mac auto-updates every 30 minutes.

## Raspberry Pi (Raspberry Pi OS with Desktop)

```bash
curl -fsSL https://raw.githubusercontent.com/palkipl/printdeck/main/setup.sh | bash
```

- Open from any PC: `http://<pi-ip>:5000` (in Chrome: ⋮ → Cast, save and share → *Install page as app*)
- On the Pi: the PrintDeck app (GTK + WebKit, no Chromium) starts full screen at login. **Esc** = leave full screen, **F11** = full screen, **Ctrl+Q** = quit, Menu → **PrintDeck** reopens it
- Settings: `~/printdeck/config.json`, then `sudo systemctl restart printdeck`
- Fan animation speed: `"fan_animation": "slow"` (or `"slower"`, `"off"`) in `~/printdeck/config.json`
- Logs: `journalctl -u printdeck -f` · Update now: `bash ~/printdeck/update.sh` · Watcher log: `journalctl -u printdeck-watch -f`
- All raw K2 data: `http://<pi-ip>:5000/api/raw`

## Mac (macOS 14 Sonoma or newer)

```bash
curl -fsSL https://raw.githubusercontent.com/palkipl/printdeck/main/mac/install.sh | bash
```

- Allow **Screen Recording** for *PrintDeck Bridge* when asked
- Settings: `~/Library/Application Support/PrintDeck/config.json`
- Preview: `http://localhost:8765` · Logs: `~/Library/Application Support/PrintDeck/*.log`
- Uninstall: `bash ~/Library/Application\ Support/PrintDeck/uninstall.sh`

### Boot order (Raspberry Pi OS)
PrintDeck starts before the desktop: the installer edits `/etc/xdg/labwc/autostart` so the PrintDeck wallpaper and app start first and the desktop/taskbar start 25 s later behind it. The original file is kept at `/etc/xdg/labwc/autostart.printdeck-orig` — copy it back to undo.
