#!/usr/bin/env bash
# PrintDeck auto-updater for the Pi (run every 30 min by printdeck-update.timer)
# Only updates when something in the repo's pi/ folder changed.
main() {
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="palkipl/printdeck"
LATEST="$(curl -fsSL "https://api.github.com/repos/$REPO/commits?path=pi&per_page=1" | grep -m1 '"sha"' | cut -d'"' -f4)"
if [ -z "$LATEST" ]; then echo "Can't reach GitHub - will try later"; exit 0; fi
CURRENT="$(cat "$DIR/.version" 2>/dev/null)"
if [ "$LATEST" = "$CURRENT" ]; then echo "Up to date (${CURRENT:0:7})"; exit 0; fi

echo "Updating ${CURRENT:0:7} -> ${LATEST:0:7}"
TMP="$(mktemp -d)"
curl -fsSL "https://github.com/$REPO/archive/$LATEST.tar.gz" | tar xz -C "$TMP" --strip-components=1
[ -f "$TMP/pi/server.py" ] || { echo "Download looked wrong, skipping"; rm -rf "$TMP"; exit 1; }
cp -r "$TMP/pi/." "$DIR/"          # config.json, go2rtc and go2rtc.yaml are not in the repo, so they're kept
rm -rf "$TMP"
echo "$LATEST" > "$DIR/.version"
bash "$DIR/install.sh" --update
}
main "$@"; exit
