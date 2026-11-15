#!/usr/bin/env bash
# Opens PrintDeck full screen. Runs at login and from the PrintDeck app icon.
# Alt+F4 exits to the desktop; it only relaunches by itself if Chromium crashes.
URL="http://localhost:5000/?kiosk=1"

pgrep -f "chromium.*localhost:5000" >/dev/null && exit 0   # already open

for i in $(seq 1 60); do
  curl -s -o /dev/null "http://localhost:5000" && break
  sleep 1
done

if [ -n "$DISPLAY" ] && command -v xset >/dev/null; then
  xset s off; xset -dpms; xset s noblank
  command -v unclutter >/dev/null && ! pgrep -x unclutter >/dev/null && unclutter -idle 0.5 -root &
fi

BROWSER="$(command -v chromium || command -v chromium-browser)"
while true; do
  "$BROWSER" --kiosk --noerrdialogs --disable-infobars --incognito \
    --no-first-run --disable-session-crashed-bubble --disable-features=Translate \
    --autoplay-policy=no-user-gesture-required --check-for-update-interval=31536000 \
    "$URL"
  [ $? -eq 0 ] && break    # closed on purpose
  sleep 3                  # crashed -> reopen
done
