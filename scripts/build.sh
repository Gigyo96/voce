#!/bin/zsh
# Compila Voce in release e assembla build/Voce.app (menu bar, LSUIElement).
#
#   scripts/build.sh            # build/Voce.app
#   scripts/build.sh --install  # copia anche in ~/Applications/Voce.app e la avvia
#
# Firma, in ordine: il certificato delle release in $VOCE_CERT_P12/$VOCE_CERT_PASSWORD (la CI, vedi
# scripts/release-cert.sh), l'identità in $VOCE_SIGN_IDENTITY, "Voce Local Signing" se esiste (vedi
# scripts/setup-signing.sh), altrimenti firma ad-hoc. Con la firma ad-hoc macOS considera ogni build
# un'app diversa e chiede di nuovo i permessi Accessibilità/Input.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64 --product Voce
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP=build/Voce.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Voce" "$APP/Contents/MacOS/Voce"
cp Voce/Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
# Icona, traduzioni (String Catalog letto a runtime) e testi di sistema tradotti (InfoPlist.strings).
cp -R Voce/Resources/ "$APP/Contents/Resources/"

KEYCHAIN="$HOME/Library/Keychains/voce-signing.keychain-db" KEYPASS=voce CERT="Voce Local Signing"
IDENTITY="${VOCE_SIGN_IDENTITY:-}"
if [[ -n "${VOCE_CERT_P12:-}" ]]; then
  # Keychain temporaneo con il certificato delle release, cancellato a fine firma.
  TMPKC=$(mktemp -d)
  KEYCHAIN="$TMPKC/release.keychain-db" KEYPASS=ci CERT="Voce Release Signing" IDENTITY=""
  print -rn -- "$VOCE_CERT_P12" | base64 --decode > "$TMPKC/release.p12"
  security create-keychain -p "$KEYPASS" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KEYPASS" "$KEYCHAIN"
  security import "$TMPKC/release.p12" -k "$KEYCHAIN" -P "${VOCE_CERT_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYPASS" "$KEYCHAIN" >/dev/null
fi
if [[ -z "$IDENTITY" && -f "$KEYCHAIN" ]]; then
  # Certificato self-signed non "trusted": codesign lo trova solo per hash e con il keychain nella
  # search list, che aggiungiamo per il tempo della firma e poi ripristiniamo.
  security unlock-keychain -p "$KEYPASS" "$KEYCHAIN"
  HASH=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v name="$CERT" 'index($0, name) {print $2; exit}')
  [[ -n "$HASH" ]] || { echo "✗ identità \"$CERT\" non trovata in $KEYCHAIN"; exit 1; }
  ORIG=("${(@f)$(security list-keychains -d user | tr -d '" ')}")
  security list-keychains -d user -s "${ORIG[@]}" "$KEYCHAIN"
  trap 'security list-keychains -d user -s "${ORIG[@]}"' EXIT
  codesign --force --deep --sign "$HASH" --identifier it.dimarcantonio.voce "$APP"
  security list-keychains -d user -s "${ORIG[@]}"
  trap - EXIT
  [[ -n "${TMPKC:-}" ]] && { security delete-keychain "$KEYCHAIN"; rm -rf "$TMPKC"; }
elif [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --sign "$IDENTITY" --identifier it.dimarcantonio.voce "$APP"
else
  echo "⚠︎ firma ad-hoc: i permessi andranno ri-concessi a ogni build (vedi scripts/setup-signing.sh)"
  codesign --force --deep --sign - --identifier it.dimarcantonio.voce "$APP"
fi
codesign -d -r- "$APP" 2>&1 | grep designated || true
echo "✓ $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Voce 2>/dev/null && sleep 1 || true
  rm -rf "$HOME/Applications/Voce.app"
  cp -R "$APP" "$HOME/Applications/Voce.app"
  open "$HOME/Applications/Voce.app"
  echo "✓ installata e avviata: ~/Applications/Voce.app"
fi
