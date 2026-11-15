#!/usr/bin/env bash
# PrintDeck one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/palkipl/printdeck/main/setup.sh | bash
set -e
cd "$HOME"
echo "-> Downloading PrintDeck"
rm -rf printdeck printdeck-main
curl -fsSL https://github.com/palkipl/printdeck/archive/refs/heads/main.tar.gz | tar xz
mv printdeck-main printdeck
cd printdeck
bash install.sh
