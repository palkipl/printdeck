#!/usr/bin/env bash
# PrintDeck installer for Raspberry Pi (Raspberry Pi OS *with Desktop*)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ME="$(whoami)"
echo "=== PrintDeck installer ==="

read -rp "Creality K2 Combo IP address (e.g. 192.168.1.50): " K2IP </dev/tty
read -rp "Camera mode [webrtc/mjpeg] (press Enter for webrtc): " CAMMODE </dev/tty
CAMMODE="${CAMMODE:-webrtc}"

cat > "$DIR/config.json" <<EOF
{
  "k2_ip": "$K2IP",
  "k2_ws_port": 9999,
  "camera_mode": "$CAMMODE",
  "go2rtc_port": 1984,
  "dashboard_port": 5000,
  "bridge_discovery_port": 47800,
  "bridge_url": ""
}
EOF
echo "-> config.json written"

echo "-> Installing packages"
sudo apt-get update
sudo apt-get install -y python3-aiohttp curl
if ! command -v chromium >/dev/null && ! command -v chromium-browser >/dev/null; then
  sudo apt-get install -y chromium || sudo apt-get install -y chromium-browser
fi
sudo apt-get install -y unclutter || true

echo "-> Downloading go2rtc (camera re-streamer)"
case "$(uname -m)" in
  aarch64) GARCH=arm64 ;;
  armv7l)  GARCH=arm ;;
  armv6l)  GARCH=armv6 ;;
  x86_64)  GARCH=amd64 ;;
  *) echo "Unknown CPU $(uname -m)"; exit 1 ;;
esac
curl -fL -o "$DIR/go2rtc" "https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_$GARCH"
chmod +x "$DIR/go2rtc"

cat > "$DIR/go2rtc.yaml" <<EOF
api:
  listen: ":1984"
  origin: "*"
rtsp:
  listen: ""
streams:
  k2: webrtc:http://$K2IP:8000/call/webrtc_local#format=creality
  k2_mjpeg: http://$K2IP:8080/?action=stream
EOF

echo "-> Creating background services"
sudo tee /etc/systemd/system/printdeck.service >/dev/null <<EOF
[Unit]
Description=PrintDeck backend
After=network-online.target
Wants=network-online.target
[Service]
User=$ME
WorkingDirectory=$DIR
ExecStart=/usr/bin/python3 $DIR/server.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/printdeck-go2rtc.service >/dev/null <<EOF
[Unit]
Description=go2rtc for PrintDeck
After=network-online.target
Wants=network-online.target
[Service]
User=$ME
WorkingDirectory=$DIR
ExecStart=$DIR/go2rtc -config $DIR/go2rtc.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now printdeck.service printdeck-go2rtc.service

echo "-> Setting up full-screen kiosk on boot"
chmod +x "$DIR/kiosk.sh"
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/printdeck-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PrintDeck Kiosk
Exec=$DIR/kiosk.sh
X-GNOME-Autostart-enabled=true
EOF

# labwc (newer Raspberry Pi OS) autostart, in case XDG autostart is off
if [ -d /etc/xdg/labwc ]; then
  mkdir -p "$HOME/.config/labwc"
  touch "$HOME/.config/labwc/autostart"
  grep -q kiosk.sh "$HOME/.config/labwc/autostart" || echo "$DIR/kiosk.sh &" >> "$HOME/.config/labwc/autostart"
  rm -f "$HOME/.config/autostart/printdeck-kiosk.desktop"   # avoid launching twice
fi

if command -v raspi-config >/dev/null; then
  sudo raspi-config nonint do_boot_behaviour B4 || true   # desktop autologin
  sudo raspi-config nonint do_blanking 1 || true          # never blank screen
fi

echo
echo "=== Done! ==="
echo "Test it now from another computer:  http://$(hostname -I | awk '{print $1}'):5000"
echo "Then reboot the Pi:                 sudo reboot"
