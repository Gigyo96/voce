#!/bin/zsh
# Crea un'identità di firma locale e stabile ("Voce Local Signing") in un keychain dedicato,
# separato dal login keychain e senza modificare impostazioni di trust del sistema.
#
# Perché: TCC (Accessibilità, Monitoraggio input) lega i permessi alla firma dell'app. Con la firma
# ad-hoc ogni build ha un hash diverso e i permessi vanno ri-concessi; con un certificato stabile no.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/voce-signing.keychain-db"
NAME="Voce Local Signing"
PASS="voce"   # protegge solo questa chiave di firma locale

if [[ -f "$KEYCHAIN" ]]; then
  echo "Keychain già presente: $KEYCHAIN"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # nessun blocco automatico
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

echo "✓ identità \"$NAME\" creata in $KEYCHAIN"
echo "  scripts/build.sh la userà automaticamente."
