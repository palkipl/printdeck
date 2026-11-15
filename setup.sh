#!/usr/bin/env bash
# PrintDeck one-line installer for Raspberry Pi:
#   curl -fsSL https://raw.githubusercontent.com/palkipl/printdeck/main/setup.sh | bash
# Safe to re-run: keeps your config.json.
main() {
set -e
REPO="palkipl/printdeck"
DEST="$HOME/printdeck"
echo "-> Downloading PrintDeck"
LATEST="$(curl -fsSL "https://api.github.com/repos/$REPO/commits?path=pi&per_page=1" | grep -m1 '"sha"' | cut -d'"' -f4 || true)"
REF="${LATEST:-main}"
TMP="$(mktemp -d)"
curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar xz -C "$TMP" --strip-components=1
mkdir -p "$DEST"
# Old v1 layout cleanup (files used to sit at the top level)
rm -rf "$DEST/static"
cp -r "$TMP/pi/." "$DEST/"
rm -rf "$TMP"
[ -n "$LATEST" ] && echo "$LATEST" > "$DEST/.version"
bash "$DEST/install.sh"
}
main "$@"; exit
