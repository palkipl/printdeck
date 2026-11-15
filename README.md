# PrintDeck

Full-screen Raspberry Pi dashboard for a **Creality K2 Combo** (live camera, print thumbnail, progress, temps, CFS filament) with a panel for the **xTool O1 Omni** fed by a Mac bridge app.

## Install (Raspberry Pi OS with Desktop)

```bash
curl -fsSL https://raw.githubusercontent.com/palkipl/printdeck/main/setup.sh | bash
```

It asks for your K2's IP address, sets up the background services, and launches the dashboard full screen on every boot. Reboot when it finishes.

- Dashboard: `http://<pi-ip>:5000`
- Settings: `~/printdeck/config.json` (then `sudo systemctl restart printdeck`)
- Logs: `journalctl -u printdeck -f`
