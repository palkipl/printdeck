#!/usr/bin/env bash
# Starts the PrintDeck app full screen. Runs at login and from Menu > PrintDeck.
# In the app: Esc = leave full screen, F11 = full screen, Ctrl+Q = quit.
# It only relaunches by itself if it crashes.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pgrep -f "printdeck_app.py" >/dev/null && { python3 "$DIR/app/printdeck_app.py" & exit 0; }  # focus existing window

if [ -n "$DISPLAY" ] && command -v xset >/dev/null; then
  xset s off; xset -dpms; xset s noblank
fi

if python3 -c "import gi; gi.require_version('WebKit2','4.1')" 2>/dev/null; then
  while true; do
    python3 "$DIR/app/printdeck_app.py"
    [ $? -eq 0 ] && break    # quit on purpose (Ctrl+Q / close)
    sleep 3                  # crashed -> reopen
  done
else
  # Fallback if the app's WebKit package is missing
  BROWSER="$(command -v chromium || command -v chromium-browser)"
  exec "$BROWSER" --kiosk --noerrdialogs --disable-infobars --incognito --no-first-run \
    --password-store=basic --allow-file-access-from-files --autoplay-policy=no-user-gesture-required \
    "file://$DIR/static/loading.html"
fi
