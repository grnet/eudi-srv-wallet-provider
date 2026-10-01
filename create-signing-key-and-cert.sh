#!/usr/bin/env bash
SIGNINGKEY_KEYALIAS=signing_alias

echo "Generating signing key..."
openssl ecparam -name prime256v1 -genkey -noout -out signing_key.pem
openssl req -new -x509 -sha256 -days 365 \
    -key signing_key.pem \
    -config signing.conf -extensions v3 \
    -out signing_cert.pem
