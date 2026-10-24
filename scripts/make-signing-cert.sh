#!/bin/zsh
# Creates a self-signed code signing identity so macOS keeps AnyCast's permissions across rebuilds and updates.
set -euo pipefail
NAME=${1:-AnyCast Local Signing}
if security find-identity -p codesigning | grep -q "$NAME"; then echo "\"$NAME\" already exists"; exit 0; fi
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cat > "$D/cfg.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cfg.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:anycast -name "$NAME"
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P anycast -T /usr/bin/codesign
echo "Created \"$NAME\". Run ./build.sh install"
