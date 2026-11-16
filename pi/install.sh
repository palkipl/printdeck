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

# ---------- packages (also checked on auto-update, installs only what's missing) ----------
PKGS="python3-aiohttp curl ffmpeg python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 \
      gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav"
[ -d /etc/xdg/labwc ] && PKGS="$PKGS swaybg"   # instant PrintDeck wallpaper at login
MISSING=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
if [ -n "$MISSING" ]; then
  echo "-> Installing:$MISSING"
  $SUDO apt-get update -q
  $SUDO apt-get install -y $MISSING
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
  listen: "127.0.0.1:8554"   # local only - used internally to make the light k2_lite stream
streams:
  k2: webrtc:http://$K2IP:8000/call/webrtc_local#format=creality
  k2_mjpeg: http://$K2IP:8080/?action=stream
  # Light version for the Pi screen: small MJPEG, only runs while someone is watching
  k2_lite: ffmpeg:k2#video=mjpeg#width=480#raw=-r 5 -q:v 8
EOF

# ---------- services ----------
echo "-> Writing background services"
$SUDO tee /etc/systemd/system/printdeck.service >/dev/null <<EOF
[Unit]
Description=PrintDeck web server
After=network.target
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
After=network.target
[Service]
User=$ME
WorkingDirectory=$DIR
ExecStart=$DIR/go2rtc -config $DIR/go2rtc.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# Update watcher: checks GitHub every 2 s, reboots after installing an update
$SUDO tee /etc/systemd/system/printdeck-watch.service >/dev/null <<EOF
[Unit]
Description=PrintDeck update watcher (checks every 2 s, reboots on update)
After=network.target
[Service]
User=$ME
ExecStart=/bin/bash $DIR/watch.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
# remove the old 30-minute timer
if [ -f /etc/systemd/system/printdeck-update.timer ]; then
  $SUDO systemctl disable --now printdeck-update.timer >/dev/null 2>&1 || true
  $SUDO rm -f /etc/systemd/system/printdeck-update.timer /etc/systemd/system/printdeck-update.service
fi

$SUDO systemctl daemon-reload
$SUDO systemctl enable printdeck.service printdeck-go2rtc.service printdeck-watch.service >/dev/null
$SUDO systemctl restart printdeck.service printdeck-go2rtc.service
# Don't restart the watcher from inside itself (it's the one running this update)
if [ $UPDATE = 1 ]; then systemctl is-active --quiet printdeck-watch.service || $SUDO systemctl start printdeck-watch.service
else $SUDO systemctl restart printdeck-watch.service; fi

# ---------- app launcher + kiosk on login ----------
chmod +x "$DIR"/*.sh
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/printdeck.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PrintDeck
Comment=3D printer dashboard
Exec=$DIR/kiosk.sh
StartupWMClass=printdeck
Icon=$DIR/branding/icon.png
Categories=Utility;
Terminal=false
EOF
rm -f "$HOME/Desktop/printdeck.desktop"   # menu entry only (Menu > Accessories/Other > PrintDeck)

rm -f "$HOME/.config/autostart/printdeck-kiosk.desktop"   # old v1 launcher
if [ -d /etc/xdg/labwc ]; then
  # Raspberry Pi OS (labwc): the desktop + taskbar start from the system autostart file,
  # so put PrintDeck first there and start the desktop 25 s later (behind the full-screen app).
  SYS=/etc/xdg/labwc/autostart
  if [ -f "$SYS" ]; then
    [ -f "$SYS.printdeck-orig" ] || $SUDO cp "$SYS" "$SYS.printdeck-orig"
    {
      echo "# --- PrintDeck (managed by ~/printdeck/install.sh; original: $SYS.printdeck-orig) ---"
      echo "command -v swaybg >/dev/null && swaybg -c '#07090d' -i '$DIR/branding/wallpaper.png' -m fit >/dev/null 2>&1 &"
      echo "'$DIR/kiosk.sh' >/dev/null 2>&1 &"
      echo "# --- desktop + taskbar, delayed so they never flash before PrintDeck ---"
      awk '/pcmanfm|wf-panel-pi/ { sub(/[ \t]*&[ \t]*$/, ""); print "(sleep 25; " $0 ") &"; next } { print }' "$SYS.printdeck-orig"
    } | $SUDO tee "$SYS.new" >/dev/null && $SUDO mv "$SYS.new" "$SYS"
  fi
  # Old setups launched PrintDeck from the user autostart file - remove that so it doesn't start twice
  if [ -f "$HOME/.config/labwc/autostart" ]; then
    sed -i "\#$DIR/kiosk.sh#d" "$HOME/.config/labwc/autostart"
    [ -s "$HOME/.config/labwc/autostart" ] || rm -f "$HOME/.config/labwc/autostart"
  fi
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
    for opt in quiet splash logo.nologo vt.global_cursor_default=0 loglevel=3 systemd.show_status=false rd.udev.log_level=3; do
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
