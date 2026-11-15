#!/usr/bin/env bash
# Opens PrintDeck full screen. Runs at login and from the PrintDeck app icon.
# Shows a PrintDeck loading screen right away, then switches to the dashboard.
# Alt+F4 exits to the desktop; it only relaunches by itself if Chromium crashes.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="file://$DIR/static/loading.html"

pgrep -f "printdeck/static/loading.html" >/dev/null && exit 0   # already open

# PrintDeck wallpaper behind everything (covers the gap before the browser opens)
command -v pcmanfm >/dev/null && pcmanfm --set-wallpaper="$DIR/branding/wallpaper.png" --wallpaper-mode=fit >/dev/null 2>&1 &

if [ -n "$DISPLAY" ] && command -v xset >/dev/null; then
  xset s off; xset -dpms; xset s noblank
  command -v unclutter >/dev/null && ! pgrep -x unclutter >/dev/null && unclutter -idle 0.5 -root &
fi

BROWSER="$(command -v chromium || command -v chromium-browser)"
while true; do
  "$BROWSER" --kiosk --noerrdialogs --disable-infobars --incognito \
    --no-first-run --disable-session-crashed-bubble --disable-features=Translate \
    --autoplay-policy=no-user-gesture-required --check-for-update-interval=31536000 \
    --allow-file-access-from-files --default-background-color=ff07090d \
    "$URL"
  [ $? -eq 0 ] && break    # closed on purpose
  sleep 3                  # crashed -> reopen
done
