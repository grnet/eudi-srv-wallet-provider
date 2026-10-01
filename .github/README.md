# EUDI Wallet Provider (GRNET fork)

Upstream repository and original README: https://github.com/eu-digital-identity-wallet/eudi-srv-wallet-provider

## Setup

The service needs a signing key/certificate pair with the following file names:

* `signing_key.pem`
* `signing_cert.pem`

These files should come from an official registration process. For
local tests, the following script can be used to generate these files:

```
./create-signing-key-and-cert.sh
```

Build a keystore with a signing key/certificate:

```
rm -f keystore.jks
./create-keystore.sh
```

## Build and run with Docker

Build a Docker image:

```
./build-docker-image.sh
docker compose up
```
