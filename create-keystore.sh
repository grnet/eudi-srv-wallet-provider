#!/usr/bin/env bash
SIGNINGKEY_KEYSTOREFILE=keystore.jks
SIGNINGKEY_KEYALIAS=signing_alias
PASSWORD=password

echo "NOTE: use password '${PASSWORD}' when prompted."

echo "Reading signing key/certificate..."
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
