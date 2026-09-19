# Deploying the wallet provider

Target is the EC2 box, `3.69.83.252`. Triggered manually from the Actions tab,
never on push.

This repository owns the **edge**: `nginx-proxy`, `acme-companion` and the
`proxy-net` network are defined in `compose.yaml` here and nowhere else. Other
service repositories declare `proxy-net` as external, so this stack has to be up
before anything else can be routed.

    compose.yaml                 the edge, postgres, keystore init, the service
    stack.env                    non-secret config, committed
    ssh/config, ssh/known_hosts  the deploy target

Secrets are passed to compose through the deploy step's environment. Compose
interpolates `${...}` client-side on the runner, so the values never touch disk
and never reach the server.

## Secrets

Set on the repository, under Settings, Secrets and variables, Actions.

| Secret | What it is |
| --- | --- |
| `SSH_KEY` | Private key authorised for `ubuntu@3.69.83.252` |
| `DATABASE_PASSWORD` | Postgres password |
| `SIGNINGKEY_KEYSTOREPASSWORD` | JWT signing keystore password |
| `TOKENSTATUSLISTSERVICE_APIKEY` | `X-API-Key` for the status list |

`SIGNINGKEY_KEYSTOREPASSWORD` is effectively permanent: `keystore-init` uses it
on first deploy and skips thereafter. Changing it means regenerating the
keystore, which changes the key at `/jwks` and invalidates every attestation
issued under the old one.

## How it works

The workflow points a compose client on the runner at the remote daemon over SSH
(`DOCKER_HOST=ssh://target`). The compose file and environment are read on the
runner and never land on the box, so there is no server-side config to drift.

`ssh/config` and `ssh/known_hosts` are committed: hostnames and host keys are
public data, and keeping them in git makes changes reviewable.

## Running a deploy

Actions, Deploy, Run workflow.

- **image_tag** defaults to the `sha-` tag of the current commit, which names
  exactly one build. A branch tag would move under a running deployment.

Verification after the roll: containers running, networks present, provider
attached to `proxy-net`, `nginx -t` passing, and `/jwks` answering through the
proxy by Host header.

## TLS

acme-companion issues a certificate for every container setting
`LETSENCRYPT_HOST`, over the HTTP-01 challenge, so the name has to resolve to
this box from public DNS.

Live as of 2026-09-19: Let's Encrypt `YR2`, valid to 2026-12-18.
`https://demo.eudiw.grnet.gr/wallet-provider/jwks` returns 200 and the chain
validates without `-k`.

Set `LETSENCRYPT_TEST=true` in `stack.env` to use the staging CA instead. Its
certificates are untrusted but the rate limits are far higher, which is worth
doing before any change that might fail issuance.

## By hand

    export DOCKER_HOST=ssh://target
    export COMPOSE_ENV_FILES=deploy/stack.env
    export WALLET_PROVIDER_IMAGE=ghcr.io/grnet/eudi-srv-wallet-provider:sha-<sha>
    export DATABASE_PASSWORD=... SIGNINGKEY_KEYSTOREPASSWORD=... TOKENSTATUSLISTSERVICE_APIKEY=...
    docker compose -f deploy/compose.yaml -p eudiw up -d

## No bind mounts

Everything the containers need arrives as an image, a named volume, or an inline
`configs:` entry. That is a constraint of driving a remote daemon rather than a
preference: compose resolves relative paths on the client and sends the daemon
absolute ones, so a bind mount points at a path on the *server*. Docker creates
it when it is missing, so the failure is a silently empty directory rather than
an error.

Both the database schema and the nginx `client_max_body_size` setting are inline
`configs:` for this reason. The schema duplicates
`schemas/postgresql/V1.sql`, so the two need to stay in step.

## Path routing

Mounted under a path on an existing hostname rather than its own name, so no new
DNS record is needed. `VIRTUAL_DEST=/` strips the prefix before forwarding, so
the application is unaware of it; `ISSUER_PUBLICURL` supplies it on the way out.

Verified 2026-09-19:

    /wallet-provider/jwks       200
    /wallet-provider/swagger    200
    jwks_uri in the metadata    http://demo.eudiw.grnet.gr/wallet-provider/jwks -> 200

Set `WALLET_PROVIDER_PATH=` empty to serve at the hostname root instead.

Two caveats. The Android app hardcodes `walletProviderHost` and needs the
prefixed value. And other services are harder: the status list builds its URL
from a hardcoded Python constant rather than config. See `WEBUILD/DOCKER.md`.

## Still to sort

- The DNS record, and TLS with it.
- gfour's manual stack still runs on that box on 5606, 5603 and 5607. Project
  name `eudiw` and no conflicting published port, so they coexist, but the old
  one should be retired.
- The image runs as root. jib defaults to uid 0 unless `jib.container.user` is
  set, which would mean patching upstream's build file. Worth raising upstream.
- `TOKENSTATUSLISTSERVICE_APIKEY` is `test`, which is what the status list
  currently validates against. It is one shared secret compared by string
  equality, not per-client, so changing it means changing every caller at the
  same time: this service, the issuer, and anything else pointed at it. Do it
  when the status list is containerised and its config is being touched anyway.
