#!/usr/bin/env bash
SIGNINGKEY_KEYSTOREFILE=keystore.jks
SIGNINGKEY_KEYALIAS=signing_alias
PASSWORD=password

echo "NOTE: use password '${PASSWORD}' when prompted."

echo "Generating signing key..."
openssl ecparam -name prime256v1 -genkey -noout -out signing_key.pem
openssl req -new -x509 -sha256 -days 365 \
    -key signing_key.pem \
    -config signing.conf -extensions v3 \
    -out signing_cert.pem
openssl pkcs12 -export -in signing_cert.pem -inkey signing_key.pem \
    -name ${SIGNINGKEY_KEYALIAS} -out out.p12

echo "Importing signing key into keystore..."
keytool -importkeystore -deststorepass ${PASSWORD} -destkeystore ${SIGNINGKEY_KEYSTOREFILE} \
     -srckeystore out.p12 -srcstoretype PKCS12

echo "SIGNINGKEY_KEYSTOREFILE=${SIGNINGKEY_KEYSTOREFILE}"
echo "SIGNINGKEY_KEYSTOREPASSWORD=${PASSWORD}"
echo "SIGNINGKEY_KEYSTORETYPE=JKS"
echo "SIGNINGKEY_KEYALIAS=${SIGNINGKEY_KEYALIAS}"
echo "SIGNINGKEY_KEYPASSWORD=${PASSWORD}"
echo "SIGNINGKEY_ALGORITHM=ES256"
