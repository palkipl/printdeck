#!/bin/bash
# PrintDeck Bridge auto-updater (run every 30 min by com.printdeck.updater)
# Only rebuilds when something in the repo's mac/ folder changed.
main() {
REPO="palkipl/printdeck"
SUPPORT="$HOME/Library/Application Support/PrintDeck"
LATEST="$(curl -fsSL "https://api.github.com/repos/$REPO/commits?path=mac&per_page=1" | grep -m1 '"sha"' | cut -d'"' -f4)"
if [ -z "$LATEST" ]; then echo "$(date) can't reach GitHub"; exit 0; fi
CURRENT="$(cat "$SUPPORT/version" 2>/dev/null)"
[ "$LATEST" = "$CURRENT" ] && exit 0
echo "$(date) updating ${CURRENT:0:7} -> ${LATEST:0:7}"
curl -fsSL "https://raw.githubusercontent.com/$REPO/$LATEST/mac/install.sh" | PRINTDECK_UPDATE=1 bash
}
main "$@"; exit
