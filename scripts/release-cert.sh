#!/bin/zsh
# Crea il certificato con cui la CI firma le release ("Voce Release Signing", self-signed, 10 anni).
#
#   scripts/release-cert.sh            # scrive ~/.voce-release/{voce-release.p12,password.txt}
#
# Perché: macOS lega i permessi (Accessibilità, Monitoraggio input, Microfono) e l'accesso al Portachiavi alla firma.
# Con la firma ad-hoc ogni versione è un'app diversa e dopo un aggiornamento i permessi smettono di funzionare;
# con lo stesso certificato a ogni release restano validi. Va creato una volta sola: se lo rigeneri, chi aggiorna
# dovrà concedere di nuovo i permessi (scripts/install.sh li azzera da solo quando la firma cambia).
#
# Poi, su GitHub › Settings › Secrets and variables › Actions, due secret:
#   VOCE_CERT_P12       = base64 del .p12     (pbcopy < ~/.voce-release/voce-release.p12.base64)
#   VOCE_CERT_PASSWORD  = la password         (pbcopy < ~/.voce-release/password.txt)
set -euo pipefail

DIR="$HOME/.voce-release"
NAME="Voce Release Signing"
[[ -e "$DIR/voce-release.p12" ]] && { echo "Esiste già: $DIR/voce-release.p12 (cancellalo per rigenerarlo)"; exit 1; }
mkdir -p "$DIR" && chmod 700 "$DIR"

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

PASS=$(/usr/bin/openssl rand -hex 24)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$DIR/voce-release.p12" -passout "pass:$PASS"
print -n "$PASS" > "$DIR/password.txt"
base64 -i "$DIR/voce-release.p12" | tr -d '\n' > "$DIR/voce-release.p12.base64"
chmod 600 "$DIR"/*

echo "✓ certificato in $DIR"
echo "  Aggiungi su GitHub i secret VOCE_CERT_P12 e VOCE_CERT_PASSWORD (vedi l'intestazione di questo script)."
