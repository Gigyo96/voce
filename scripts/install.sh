#!/bin/bash
# Installs the latest Voce release:
#
#   curl -fsSL https://raw.githubusercontent.com/Gigyo96/voce/main/scripts/install.sh | bash
#
# Voce is not notarized (no paid Apple Developer ID). Files downloaded with curl are not quarantined,
# so Gatekeeper does not block the app; the quarantine flag is cleared anyway for zips fetched by a browser.
set -euo pipefail

URL="https://github.com/Gigyo96/voce/releases/latest/download/Voce.zip"

[[ "$(uname -m)" == arm64 ]] || { echo "Voce needs a Mac with Apple Silicon (M1 or later)."; exit 1; }
(( $(sw_vers -productVersion | cut -d. -f1) >= 15 )) || { echo "Voce needs macOS 15 Sequoia or later."; exit 1; }

DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "↓ Downloading Voce…"
curl -fL --progress-bar -o "$TMP/Voce.zip" "$URL"
ditto -x -k "$TMP/Voce.zip" "$TMP"

pkill -x Voce 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Voce.app"
mv "$TMP/Voce.app" "$DEST/Voce.app"
xattr -dr com.apple.quarantine "$DEST/Voce.app" 2>/dev/null || true
open "$DEST/Voce.app"

echo "✓ Installed in $DEST/Voce.app and launched."
echo "  Voce lives in the menu bar: grant Microphone, Accessibility and Input Monitoring in the window that opens."
