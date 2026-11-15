#!/bin/bash
# PrintDeck Bridge installer for macOS 14 Sonoma or newer
#   curl -fsSL https://raw.githubusercontent.com/palkipl/printdeck/main/mac/install.sh | bash
# Re-running it is safe (keeps your config). The auto-updater runs it with PRINTDECK_UPDATE=1.
main() {
set -e
REPO="palkipl/printdeck"
APP="$HOME/Applications/PrintDeck Bridge.app"
SUPPORT="$HOME/Library/Application Support/PrintDeck"
AGENTS="$HOME/Library/LaunchAgents"
BRIDGE_PLIST="$AGENTS/com.printdeck.bridge.plist"
UPDATER_PLIST="$AGENTS/com.printdeck.updater.plist"
GUI="gui/$(id -u)"
UPDATE="${PRINTDECK_UPDATE:-0}"
CERT="PrintDeck Signing"
echo "=== PrintDeck Bridge installer $([ "$UPDATE" = 1 ] && echo '(update)') ==="

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 14 ]; then echo "Needs macOS 14 Sonoma or newer (you have $(sw_vers -productVersion))."; exit 1; fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  if [ "$UPDATE" = 1 ]; then echo "swiftc missing - skipping update"; exit 1; fi
  echo "Apple's Command Line Tools are needed to build the app. A window will pop up - click Install."
  xcode-select --install 2>/dev/null || true
  echo "When that finishes, run this same install command again."
  exit 1
fi

mkdir -p "$SUPPORT" "$AGENTS" "$HOME/Applications"

# ---------- config ----------
if [ ! -f "$SUPPORT/config.json" ]; then
  OMNIIP=""
  if [ "$UPDATE" != 1 ]; then
    echo "The Omni is detected over USB by default. Only type an IP if it's on Wi-Fi/Ethernet."
    read -rp "Omni IP address (press Enter for USB): " OMNIIP </dev/tty || true
  fi
  cat > "$SUPPORT/config.json" <<EOF
{
  "omni_ip": "$OMNIIP",
  "port": 8765,
  "window_match": "xTool",
  "fps": 2,
  "max_width": 1280,
  "device_name": "xTool O1 Omni",
  "usb_match": "xtool",
  "screen_capture": false
}
EOF
  echo "-> Config saved to $SUPPORT/config.json"
fi

# ---------- download the exact latest version ----------
LATEST="$(curl -fsSL "https://api.github.com/repos/$REPO/commits?path=mac&per_page=1" | grep -m1 '"sha"' | cut -d'"' -f4 || true)"
REF="${LATEST:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$REF/mac"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$RAW/PrintDeckBridge.swift" -o "$TMP/main.swift"
curl -fsSL "$RAW/update.sh" -o "$SUPPORT/update.sh"
curl -fsSL "$RAW/uninstall.sh" -o "$SUPPORT/uninstall.sh"
chmod +x "$SUPPORT/update.sh" "$SUPPORT/uninstall.sh"

echo "-> Compiling PrintDeck Bridge (takes ~30 s)"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$TMP/main.swift" -o "$TMP/PrintDeckBridge"

# ---------- stable signing identity (so Screen Recording permission survives updates) ----------
if ! security find-certificate -c "$CERT" >/dev/null 2>&1 && [ "$UPDATE" != 1 ]; then
  echo "-> Creating a local code-signing certificate (macOS may ask for your password)"
  cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=PrintDeck Signing
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
  (
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1 &&
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$CERT" \
      -out "$TMP/pd.p12" -passout pass:printdeck >/dev/null 2>&1 &&
    security import "$TMP/pd.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P printdeck -T /usr/bin/codesign >/dev/null &&
    security add-trusted-cert -r trustRoot -p codeSign \
      -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
  ) || echo "   (certificate setup skipped - will use basic signing)"
fi

# ---------- build the .app ----------
launchctl bootout "$GUI" "$BRIDGE_PLIST" 2>/dev/null || true
pkill -x PrintDeckBridge 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$TMP/PrintDeckBridge" "$APP/Contents/MacOS/PrintDeckBridge"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.printdeck.bridge</string>
  <key>CFBundleName</key><string>PrintDeck Bridge</string>
  <key>CFBundleDisplayName</key><string>PrintDeck Bridge</string>
  <key>CFBundleExecutable</key><string>PrintDeckBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${REF:0:7}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>PrintDeck Bridge shares the xTool Omni view with your PrintDeck Raspberry Pi.</string>
</dict></plist>
EOF
if codesign --force -s "$CERT" "$APP" 2>/dev/null; then
  echo "-> Signed with '$CERT'"
else
  codesign --force -s - "$APP"
  echo "-> Signed ad-hoc (you may need to re-allow Screen Recording after updates)"
fi
echo "$LATEST" > "$SUPPORT/version"

# ---------- launch at login + keep running ----------
cat > "$BRIDGE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.printdeck.bridge</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/PrintDeckBridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$SUPPORT/bridge.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/bridge.log</string>
</dict></plist>
EOF
launchctl bootstrap "$GUI" "$BRIDGE_PLIST"

# ---------- auto-updater (every 30 min) ----------
cat > "$UPDATER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.printdeck.updater</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SUPPORT/update.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>$SUPPORT/update.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/update.log</string>
</dict></plist>
EOF
if [ "$UPDATE" != 1 ]; then
  launchctl bootout "$GUI" "$UPDATER_PLIST" 2>/dev/null || true
  launchctl bootstrap "$GUI" "$UPDATER_PLIST"
fi

echo
echo "=== PrintDeck Bridge is running (printer icon in your menu bar) ==="
if [ "$UPDATE" != 1 ]; then
  echo "1. If asked about 'local network' or incoming connections, click Allow."
  echo "2. Screen capture of xTool Studio is OFF (no Screen Recording permission needed)."
  echo "   To turn it on later, set \"screen_capture\": true in $SUPPORT/config.json"
fi
}
main "$@"; exit
