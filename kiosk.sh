#!/usr/bin/env bash
# Launches the dashboard full screen. Started automatically at login.
URL="http://localhost:5000"

# Wait for the backend to come up
for i in $(seq 1 60); do
  curl -s -o /dev/null "$URL" && break
  sleep 1
done

# Keep the screen awake + hide mouse (X11 only; harmless on Wayland)
if [ -n "$DISPLAY" ] && command -v xset >/dev/null; then
  xset s off; xset -dpms; xset s noblank
  command -v unclutter >/dev/null && unclutter -idle 0.5 -root &
fi

BROWSER="$(command -v chromium || command -v chromium-browser)"

# Relaunch if it ever crashes
while true; do
  "$BROWSER" \
    --kiosk --noerrdialogs --disable-infobars --incognito \
    --no-first-run --disable-session-crashed-bubble --disable-features=Translate \
    --autoplay-policy=no-user-gesture-required \
    --check-for-update-interval=31536000 \
    "$URL"
  sleep 3
done
