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

# macOS lega i permessi alla firma dell'app: si confronta quella installata con quella nuova.
requirement() { codesign -d -r- "$1" 2>&1 | grep designated || true; }
OLD_REQ=""
[[ -d "$DEST/Voce.app" ]] && OLD_REQ=$(requirement "$DEST/Voce.app")

pkill -x Voce 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Voce.app"
mv "$TMP/Voce.app" "$DEST/Voce.app"
xattr -dr com.apple.quarantine "$DEST/Voce.app" 2>/dev/null || true

RESET=0
if [[ -n "$OLD_REQ" && "$OLD_REQ" != "$(requirement "$DEST/Voce.app")" ]]; then
  # Firma cambiata (succede una volta, passando dalla v1.0.0 firmata ad-hoc): i vecchi permessi resterebbero accesi in
  # Impostazioni di Sistema ma senza effetto. Si azzerano, così macOS li chiede di nuovo e funzionano.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Voce.app" || true
  tccutil reset All it.dimarcantonio.voce >/dev/null 2>&1 && RESET=1 || true
fi
open "$DEST/Voce.app"

echo "✓ Installata in $DEST/Voce.app e avviata."
if (( RESET )); then
  echo "  Questa versione ha una firma nuova: concedi di nuovo Microfono, Accessibilità e Monitoraggio input nella"
  echo "  finestra che si apre. Dai prossimi aggiornamenti i permessi restano."
else
  echo "  Voce vive nella barra dei menu: nella finestra che si apre concedi Microfono, Accessibilità e Monitoraggio input."
fi
