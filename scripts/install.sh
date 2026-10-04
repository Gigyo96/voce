#!/bin/bash
# Installa l'ultima versione di Voce:
#
#   curl -fsSL https://raw.githubusercontent.com/Gigyo96/voce/main/scripts/install.sh | bash
#
# Voce non è notarizzata (servirebbe un Apple Developer ID a pagamento). I file scaricati con curl non sono in
# quarantena, quindi Gatekeeper non blocca l'app; il flag si toglie comunque, nel caso lo zip arrivi da un browser.
set -euo pipefail

URL="https://github.com/Gigyo96/voce/releases/latest/download/Voce.zip"

[[ "$(uname -m)" == arm64 ]] || { echo "Voce richiede un Mac con Apple Silicon (M1 o successivo)."; exit 1; }
(( $(sw_vers -productVersion | cut -d. -f1) >= 15 )) || { echo "Voce richiede macOS 15 Sequoia o successivo."; exit 1; }

DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "↓ Scarico Voce…"
curl -fL --progress-bar -o "$TMP/Voce.zip" "$URL"
ditto -x -k "$TMP/Voce.zip" "$TMP"

pkill -x Voce 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Voce.app"
mv "$TMP/Voce.app" "$DEST/Voce.app"
xattr -dr com.apple.quarantine "$DEST/Voce.app" 2>/dev/null || true
open "$DEST/Voce.app"

echo "✓ Installata in $DEST/Voce.app e avviata."
echo "  Voce vive nella barra dei menu: nella finestra che si apre concedi Microfono, Accessibilità e Monitoraggio input."
