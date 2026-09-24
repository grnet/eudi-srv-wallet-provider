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
prefixed value. The status list used to be harder, building its URL from a
hardcoded Python constant, but it now reads `SERVICE_URL` from the environment.
See `WEBUILD/DOCKER.md`.

## This stack carries routing fixes for other services

nginx-proxy and the `proxy-vhost` volume belong here, so per-path nginx config
for *any* service on this hostname is declared in this compose file. Three
`configs:` entries exist for that reason, and none of them is about the wallet
provider:

| Config | For | Why |
| --- | --- | --- |
| `well-known-discovery` | issuer, OIDC, issuer frontend | RFC 8414 puts discovery metadata at the host root, which belongs to the status list |
| `verifier-ui-base-href` | verifier UI | Angular bakes `<base href="/">`, so assets resolve to the host root |
| `issuer-frontend-static` | issuer frontend | Flask `url_for('static')` emits absolute `/static/...`, same effect |

Keeping them here means those forks carry no deployment-specific changes.
`eudi-web-verifier` in particular has **zero drift from upstream**.

The cost is that a service's routing can live in a different repository from the
service, and that this stack must be deployed before the ones that depend on it.

### Per-path config files, and the trap

Named `<host>_<sha1 of VIRTUAL_PATH>_location`, where the hash has **no trailing
newline**:

    printf '%s' '/frontend/' | shasum

A hash matching no generated location is silently ignored. Nothing errors, and
the page is simply broken.

**Adding one needs the proxy recreated, not reloaded.** docker-gen writes the
`include` line only when the file exists at template-generation time, so
dropping a file in and running `nginx -s reload` does nothing at all. Use
`RECREATE=1 ./deploy.sh`. The same applies to changing a config's *content*:
compose does not recreate a container when only that changed.

## Still to sort

- The DNS record, and TLS with it.
- gfour's manual stack still runs on that box on 5606, 5603 and 5607. Project
  name `eudiw` and no conflicting published port, so they coexist. The box is
  being scrapped rather than cleaned up, so retiring them is not worth the work.
- `TOKENSTATUSLISTSERVICE_SERVICEURL` is now portless, pointing at the
  containerised status list on 443. It has to change in lockstep with that
  service's own `SERVICE_URL`: the wallet provider calls the URL, the status list
  signs it into tokens as `sub`, and if the two disagree the tokens point
  somewhere the caller never used.
- The image runs as root. jib defaults to uid 0 unless `jib.container.user` is
  set, which would mean patching upstream's build file. Worth raising upstream.
- `TOKENSTATUSLISTSERVICE_APIKEY` is `test`, which is what the status list
  currently validates against. It is one shared secret compared by string
  equality, not per-client, so changing it means changing every caller at the
  same time: this service, the issuer, and anything else pointed at it. Do it
  when the status list is containerised and its config is being touched anyway.
