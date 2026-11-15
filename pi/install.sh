#!/usr/bin/env bash
# PrintDeck installer for Raspberry Pi (Raspberry Pi OS *with Desktop*)
#   First install:  bash install.sh
#   Auto-update:    bash install.sh --update   (no questions, no apt)
main() {
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME="$(whoami)"
UPDATE=0; [ "$1" = "--update" ] && UPDATE=1
SUDO="sudo"; [ $UPDATE = 1 ] && SUDO="sudo -n"
echo "=== PrintDeck installer $([ $UPDATE = 1 ] && echo '(update)') ==="

# ---------- config ----------
if [ ! -f "$DIR/config.json" ]; then
  if [ $UPDATE = 1 ]; then echo "No config.json - run install.sh normally first"; exit 1; fi
  read -rp "Creality K2 Combo IP address (e.g. 192.168.1.50): " K2IP </dev/tty
  read -rp "Camera mode [webrtc/mjpeg] (press Enter for webrtc): " CAMMODE </dev/tty
  CAMMODE="${CAMMODE:-webrtc}"
  sed -e "s/\"k2_ip\": \"\"/\"k2_ip\": \"$K2IP\"/" \
      -e "s/\"camera_mode\": \"webrtc\"/\"camera_mode\": \"$CAMMODE\"/" \
      "$DIR/config.example.json" > "$DIR/config.json"
  echo "-> config.json written"
else
  echo "-> Keeping your existing config.json"
fi
K2IP="$(python3 -c "import json;print(json.load(open('$DIR/config.json'))['k2_ip'])")"

# ---------- packages (first install only) ----------
if [ $UPDATE = 0 ]; then
  echo "-> Installing packages"
  sudo apt-get update
  sudo apt-get install -y python3-aiohttp curl
  if ! command -v chromium >/dev/null && ! command -v chromium-browser >/dev/null; then
    sudo apt-get install -y chromium || sudo apt-get install -y chromium-browser
  fi
  sudo apt-get install -y unclutter || true
fi

# ---------- go2rtc ----------
if [ $UPDATE = 0 ] || [ ! -x "$DIR/go2rtc" ]; then
  echo "-> Downloading go2rtc (camera re-streamer)"
  case "$(uname -m)" in
    aarch64) GARCH=arm64 ;; armv7l) GARCH=arm ;; armv6l) GARCH=armv6 ;; x86_64) GARCH=amd64 ;;
    *) echo "Unknown CPU $(uname -m)"; exit 1 ;;
  esac
  # Download to a temp file and swap it in - works even while go2rtc is running
  curl -fL -o "$DIR/go2rtc.new" "https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_$GARCH"
  chmod +x "$DIR/go2rtc.new"
  mv -f "$DIR/go2rtc.new" "$DIR/go2rtc"
fi
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

# ---------- services ----------
echo "-> Writing background services"
$SUDO tee /etc/systemd/system/printdeck.service >/dev/null <<EOF
[Unit]
Description=PrintDeck web server
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

$SUDO tee /etc/systemd/system/printdeck-go2rtc.service >/dev/null <<EOF
[Unit]
Description=PrintDeck camera re-streamer (go2rtc)
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

$SUDO tee /etc/systemd/system/printdeck-update.service >/dev/null <<EOF
[Unit]
Description=PrintDeck auto-updater
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=$ME
ExecStart=/bin/bash $DIR/update.sh
EOF

$SUDO tee /etc/systemd/system/printdeck-update.timer >/dev/null <<EOF
[Unit]
Description=Check GitHub for PrintDeck updates every 30 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=30min
[Install]
WantedBy=timers.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable printdeck.service printdeck-go2rtc.service printdeck-update.timer >/dev/null
$SUDO systemctl restart printdeck.service printdeck-go2rtc.service
$SUDO systemctl start printdeck-update.timer

# ---------- app launcher + kiosk on login ----------
chmod +x "$DIR"/*.sh
mkdir -p "$HOME/.local/share/applications" "$HOME/Desktop"
cat > "$HOME/.local/share/applications/printdeck.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PrintDeck
Comment=3D printer dashboard
Exec=$DIR/kiosk.sh
Icon=$DIR/branding/icon.png
Categories=Utility;
Terminal=false
EOF
cp "$HOME/.local/share/applications/printdeck.desktop" "$HOME/Desktop/printdeck.desktop"
chmod +x "$HOME/Desktop/printdeck.desktop"

rm -f "$HOME/.config/autostart/printdeck-kiosk.desktop"   # old v1 launcher
if [ -d /etc/xdg/labwc ]; then
  mkdir -p "$HOME/.config/labwc"; touch "$HOME/.config/labwc/autostart"
  grep -q "$DIR/kiosk.sh" "$HOME/.config/labwc/autostart" || echo "$DIR/kiosk.sh &" >> "$HOME/.config/labwc/autostart"
else
  mkdir -p "$HOME/.config/autostart"
  cp "$HOME/.local/share/applications/printdeck.desktop" "$HOME/.config/autostart/printdeck.desktop"
fi

# ---------- PrintDeck boot screen ----------
brand_boot() {
  local SRC="$DIR/branding/plymouth" DST=/usr/share/plymouth/themes/printdeck
  if command -v plymouth-set-default-theme >/dev/null; then
    local NEW OLD CUR
    NEW="$(cat "$SRC"/* | md5sum | cut -d' ' -f1)"
    OLD="$(cat "$DST"/* 2>/dev/null | md5sum | cut -d' ' -f1)"
    CUR="$(plymouth-set-default-theme 2>/dev/null)"
    if [ "$NEW" != "$OLD" ] || [ "$CUR" != "printdeck" ]; then
      echo "-> Installing PrintDeck boot screen (rebuilding boot image, takes 1-3 min on a Pi 3)"
      $SUDO mkdir -p "$DST"
      $SUDO cp "$SRC"/* "$DST"/
      $SUDO plymouth-set-default-theme -R printdeck
    fi
  else
    echo "   (plymouth not installed - skipping boot screen)"
  fi
  local CMD=/boot/firmware/cmdline.txt
  [ -f "$CMD" ] || CMD=/boot/cmdline.txt
  if [ -f "$CMD" ]; then
    for opt in quiet splash logo.nologo vt.global_cursor_default=0; do
      grep -qE "(^| )$opt( |\$)" "$CMD" || $SUDO sed -i "1 s/\$/ $opt/" "$CMD"
    done
  fi
  local CFGTXT=/boot/firmware/config.txt
  [ -f "$CFGTXT" ] || CFGTXT=/boot/config.txt
  if [ -f "$CFGTXT" ] && ! grep -q '^disable_splash=1' "$CFGTXT"; then
    echo "disable_splash=1" | $SUDO tee -a "$CFGTXT" >/dev/null   # hide the rainbow screen
  fi
}
brand_boot || echo "   (boot screen setup skipped)"

if [ $UPDATE = 0 ] && command -v raspi-config >/dev/null; then
  sudo raspi-config nonint do_boot_behaviour B4 || true   # desktop autologin
  sudo raspi-config nonint do_blanking 1 || true          # never blank the screen
fi

IP="$(hostname -I | awk '{print $1}')"
echo
echo "=== PrintDeck ready ==="
echo "Open from any PC:   http://$IP:5000"
[ $UPDATE = 0 ] && echo "Reboot the Pi now:  sudo reboot"
}
main "$@"; exit
