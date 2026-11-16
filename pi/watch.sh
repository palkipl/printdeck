#!/usr/bin/env bash
# PrintDeck update watcher: checks GitHub every 2 seconds.
# Uses git's lightweight ref check (no API rate limit). When the repo changes,
# runs update.sh, which only installs if the Pi's files changed - then reboots.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="palkipl/printdeck"
SEEN="$DIR/.main_seen"
INTERVAL=2

while true; do
  SHA="$(curl -fsS -m 5 "https://github.com/$REPO.git/info/refs?service=git-upload-pack" 2>/dev/null \
        | grep -a -o '[0-9a-f]\{40\} refs/heads/main' | head -1 | cut -c1-40)"
  if [ -n "$SHA" ] && [ "$SHA" != "$(cat "$SEEN" 2>/dev/null)" ]; then
    echo "$(date '+%F %T') repo changed -> ${SHA:0:7}"
    if bash "$DIR/update.sh" --reboot; then
      echo "$SHA" > "$SEEN"
    else
      sleep 30   # update failed (e.g. GitHub busy) - try again shortly
    fi
  fi
  sleep "$INTERVAL"
done
