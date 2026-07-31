# EUDI Wallet Provider (GRNET fork)

Upstream repository and original README: https://github.com/eu-digital-identity-wallet/eudi-srv-wallet-provider

## Setup

Build a keystore with a signing key/certificate:

```
rm -f keystore.jks
./create-jks.sh
```

## Build and run with Docker

Build a Docker image:

```
./build-docker-image.sh
docker compose up
```
