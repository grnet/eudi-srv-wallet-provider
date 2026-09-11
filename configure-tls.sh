#!/usr/bin/env bash

if [[ -f ".config.hostname" ]]; then
    HOST=$(cat .config.hostname)
else
    echo "File not found: .config.hostname"
fi

echo "Use 'password' for all passwords"

openssl pkcs12 -export -in /etc/letsencrypt/live/${HOST}/fullchain.pem -inkey /etc/letsencrypt/live/${HOST}/privkey.pem -out tls.p12 -name "tls"
keytool -importkeystore -srckeystore tls.p12 -srcstoretype pkcs12 -destkeystore keystore.jks
