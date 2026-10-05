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
| `SIGNING_KEY_PEM` | Attestation signing key, PKCS#8 PEM. See "The signing key" |
| `TOKENSTATUSLISTSERVICE_APIKEY` | `X-API-Key` for the status list |

And one variable, under the Variables tab, because it is public:

| Variable | What it is |
| --- | --- |
| `SIGNING_CERT_PEM` | The signing key's certificate, followed by the CA that issued it |

`keystore-init` rebuilds the keystore from these on every deploy, so
`SIGNINGKEY_KEYSTOREPASSWORD` can change freely.

## The signing key

The provider signs wallet instance attestations and key attestations, and
sends its certificate chain as their `x5c`. Issuers outside this demo trust
an attestation when that certificate is on WE BUILD's Wallet Providers list:

    https://tl-api.dev.idunion.info/api/v1/8djrdSZa/etsi/tl.xml

GRNET's entry there was onboarded on 2026-09-18, through the idunion console,
with a key pair and CSR of our own:

    subject   C=GR, ST=Attica, L=Athens, O=GRNET, CN=grnet.gr
    issuer    O=WEBUILD - WP 4 - Group 5 - Trust Registry Infrastructure
    valid     2026-09-18 to 2028-09-18
    SHA-256   5E:FF:92:2F:39:D8:97:89:86:B7:AA:D0:57:17:7F:1D:90:1D:17:E3:19:F7:81:FA:67:D1:68:22:8D:96:41:AC

The onboarding produced `private.key` and `x509_certificate.pem`. The PEM holds
our certificate and then the CA. Use it as it is. The deploy checks our
certificate against the CA, and the keystore holds both. `x5c` carries only our
certificate: the app drops a self-signed root from the end of the chain
(`dropRootCaIfNeeded`), and the WE BUILD CA is one. That is what the list
matches anyway.

    gh secret set SIGNING_KEY_PEM < private.key
    gh variable set SIGNING_CERT_PEM < x509_certificate.pem

Before touching the box, the deploy checks that the key is the first
certificate's and that the first certificate verifies against the CA after
it. A single certificate with no CA only gets a warning, so that rolling back
to a self-signed key still works. After the deploy, it checks that `/jwks`
publishes that chain, with or without its last certificate.

**Then deploy the issuer.** Its OIDC server trusts wallet attestations by the
certificate it reads from this service's `/jwks` at deploy time, so until
`eudi-srv-web-issuing-eudiw-py` is redeployed our own wallet cannot get a
PID. A plain deploy is enough: the certificate's hash is in that server's
environment, so compose recreates it.

Changing the key invalidates every attestation issued under the old one.
Wallets fetch fresh ones, which are short-lived, so the effect is a one-off
failed request rather than a migration.

To go back to an earlier key, take it out of a copy of the old keystore and
set it as above:

    keytool -importkeystore -srckeystore keystore.jks -destkeystore old.p12 -deststoretype PKCS12
    openssl pkcs12 -in old.p12 -nocerts -nodes | openssl pkey > private.key
    openssl pkcs12 -in old.p12 -nokeys > x509_certificate.pem

The keystore on the box before the switch held a self-signed certificate,
`CN=GRNET Wallet Backend Signer`, SHA-256 `E4:3C:BA:A9:…:96:61:32`.

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
attached to `proxy-net`, `nginx -t` passing, `/jwks` answering through the
proxy by Host header, and publishing `SIGNING_CERT_PEM` as its `x5c`, less
the root CA.

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
    export SIGNING_KEY_PEM="$(cat private.key)" SIGNING_CERT_PEM="$(cat x509_certificate.pem)"
    export SIGNING_CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 <<< "$SIGNING_CERT_PEM" | cut -d= -f2)
    export LANDING_SHA256=...   # computed by the workflow, see "The landing page at /"
    docker compose -f deploy/compose.yaml -p eudiw up -d

None of the workflow's checks run this way.

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

Two caveats. The Android app's dev flavour takes the URL as a build argument,
and it has to include the prefix:

    -PwalletProviderUrl=https://demo.eudiw.grnet.gr/wallet-provider

The status list used to be harder, building its URL from a hardcoded Python
constant, but it now reads `SERVICE_URL` from the environment. See
"Configuration" in `eudi-srv-statuslist-py`'s `deploy/README.md`.

## This stack carries routing fixes for other services

nginx-proxy and the `proxy-vhost` volume belong here, so per-path nginx config
for *any* service on this hostname is declared in this compose file. Four
`configs:` entries exist for that reason, and none of them is about the wallet
provider:

| Config | For | Why |
| --- | --- | --- |
| `well-known-discovery` | issuer, OIDC, issuer frontend | RFC 8414 puts discovery metadata at the host root, which belongs to the status list |
| `verifier-ui-base-href` | verifier UI | Angular bakes `<base href="/">`, so assets resolve to the host root |
| `issuer-frontend-static` | issuer frontend | Flask `url_for('static')` emits absolute `/static/...`, same effect |
| `http-with-crl-exception` | CRL | the CRL must answer on plain http without a redirect; see below |

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
dropping a file in and running `nginx -s reload` does nothing at all. Tick
**Recreate containers even if nothing changed** in the Deploy workflow. The
same applies to changing a config's *content*:
compose does not recreate a container when only that changed.

### The landing page at /

`eudiw-landing`, stock nginx serving one static page: the demo's front door.
It links the services, gives the IACA with its fingerprint for partners to
check a download against, and sends people to the Android wallet's GitHub
Releases, with the certificate its APKs are signed with.

It lives here because it describes the routes this stack's edge defines, so
the two change together. No JavaScript, every link relative so nothing names
the host, and a strict `Content-Security-Policy`. As `VIRTUAL_PATH=/` it is the
hostname's catch-all: any path no service claims gets its plain 404.

Its header carries the EUDI Wallet and gov.gr BETA logos side by side, as the
Android wallet's home screen and the verifier UI do. They are the verifier
UI's own `ic-logo.svg` and `logo_govgr_pos.svg`, unmodified, per the
[gov.gr brand guide](https://guide.services.gov.gr/docs/brand), served from
`/landing/` (the CSP allows `img-src 'self'`). Their configs are in
`deploy/landing-logos.yaml`, which `compose.yaml` includes, so 70 KB of path
data stays out of the page's markup.

Editing the page means editing `landing-html` in `deploy/compose.yaml` and
deploying; a plain deploy is enough. The deploy workflow renders every
`landing-*` config (the page, its nginx config and the logos) with the
`stack.env` values in them, and passes a hash of the result
to the container as `LANDING_SHA256`, which nginx never reads. A change to the
page, or to a value it shows, changes that hash and so the service definition,
and compose recreates the container. Without it, compose would keep serving
the old page, as it did on 2026-09-29.

**The fingerprint is `IACA_SHA256` in `stack.env`, and must change on an IACA
reissue.** The certificate itself is served from the issuer's stack at `/pki/`,
so the two are in different repositories and have to be kept in step by hand.

**The wallet app is `WALLET_RELEASES_URL` and `WALLET_APK_CERT_SHA256` in
`stack.env`.** The certificate changes only if the app's keystore does.
Nothing checks them automatically: when either changes, confirm that the link
answers and that the certificate matches the one named in the notes of the
app's release marked Latest.

If it grows into several pages, or people outside this repo should edit it,
move it to a repository of its own.

### Port 80 is ours, not nginx-proxy's

The IACA names `http://<host>/revocation/crl.pem` as its CRL distribution point,
signed into every certificate under it. That one path must answer on plain http,
because a JVM verifier will not follow an http to https redirect. Everything
else must keep redirecting.

nginx-proxy cannot express that. `HTTPS_METHOD` is per hostname, not per path:
its template takes the value from the first container on the host that sets it,
so `noredirect` on the CRL container would drop the redirect **and HSTS** for
every service here. The generated port-80 server has no include hook either,
only the ACME location and a blanket 301.

So `http-with-crl-exception` replaces that server. Mounted as
`conf.d/00-http-with-crl-exception.conf`, it loads before the generated
`default.conf`, and nginx keeps the first server for a given name and port. The
generated one is ignored, with a warning `nginx -t` prints on every run:

    conflicting server name "demo.eudiw.grnet.gr" on 0.0.0.0:80, ignored

That warning is the mechanism working, not a fault. The `00-` prefix is
load-bearing.

It has three locations:

| Location | Does |
| --- | --- |
| `/.well-known/acme-challenge/` | copied verbatim from nginx-proxy 1.11's template |
| `/revocation/` | proxies to `eudiw-crl`, resolved per request |
| `/` | 301 to https, as the generated server did |

**The ACME location is the dangerous part.** If it drifts from what
acme-companion expects, certificate renewal fails, and nothing shows it until
the certificate expires. The deploy workflow therefore writes a probe file into
the challenge directory and fetches it over http. **Recheck it against the
template when upgrading nginx-proxy**: `/app/nginx.tmpl` in the container.

The CRL upstream is resolved at request time through Docker's DNS
(`resolver 127.0.0.11`), not at startup. A static `proxy_pass http://eudiw-crl`
would stop nginx from starting on a box where the issuer stack is not up yet,
taking every service down with it. This way it is a 502 on one path.

`eudiw-crl` is the CRL's `container_name` in `eudi-srv-web-issuing-eudiw-py`,
and `CRL_PATH` in `stack.env` must match that stack's. Tested 2026-09-24 on a
second nginx instance in the proxy container on an unpublished port before going
live: ACME 200, `/revocation/` routed, every other path 301, bare-IP requests
still dropped.

## Still to sort

- gfour's manual stack is being retired. As of 2026-09-28, 5606 and 5607 still
  answer on that box and 5603 does not. No conflicting published port, so the
  two coexist until then. Every service it ran now has a replacement here,
  including the CRL. The one thing without one is the APK download, which
  `:5607` also serves.
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
