# Rackoon for the web: running it

Rackoon for the web is one Docker image you run yourself: a Python backend that holds the SSH connections and a
browser UI that only shows what the backend works out. Nothing is installed on the servers it manages; it is just
another SSH client. It has the Mac app's Overview, Terminal, Docker, Updates, Services, Commands, Files, Alerts and
Search, and changes nothing on a server without showing you the exact command first.

**Keep it on your tailnet.** It can open a root shell on every server you add. Never publish its port on the open
internet or your LAN; reach it through Tailscale (or another private network) with HTTPS.

## Try it without a server

```bash
docker run --rm -p 127.0.0.1:8080:8080 -e RACKOON_DEMO=1 ghcr.io/bgallagher/rackoon-web:latest
```

Open http://localhost:8080. Demo mode has made-up servers, needs no sign-in, keeps nothing, and sends nothing
anywhere (the demo's sudo password is `demo`).

## Install

### A. On a host that is already on your tailnet (simplest)

1. Copy [web/deploy/compose.yaml](../web/deploy/compose.yaml) to the host and run `docker compose up -d`. It
   publishes Rackoon on 127.0.0.1:8080 only.
2. Give it HTTPS on your tailnet: `tailscale serve --bg --https=443 http://127.0.0.1:8080`. Rackoon is then at
   `https://<host>.<your-tailnet>.ts.net`.

### B. As its own Tailscale node

[web/deploy/compose.tailscale.yaml](../web/deploy/compose.tailscale.yaml) runs a Tailscale container next to Rackoon
(with [serve.json](../web/deploy/serve.json) for HTTPS), so the host needs no Tailscale. Put an auth key in `.env`
(`TS_AUTHKEY=tskey-auth-...`, ideally tagged, e.g. `tag:rackoon`, with ACLs that let it reach only your servers'
port 22) and run `docker compose -f compose.tailscale.yaml up -d`. Rackoon is at `https://rackoon.<your-tailnet>.ts.net`.

### HTTPS is required

The sign-in cookie is `__Host-` prefixed, HttpOnly, Secure and SameSite=Strict, so browsers keep it only over HTTPS (or
on localhost). Over plain http on another address, signing in silently does nothing; the sign-in page says so.

## First sign-in

On first start Rackoon logs a one-time setup token (also in `/data/setup-token`):

```bash
docker compose logs rackoon | grep "setup token"
```

Open Rackoon, enter the token and choose the admin password (12 characters or more; stored as an argon2id hash).
Instead, you can set `RACKOON_ADMIN_PASSWORD_FILE` to a Docker secret holding the password (or an argon2id hash of it);
then there is no setup step and the password can't be changed from the UI. Settings > Account turns on a TOTP code.

Behind an identity-aware proxy (Authelia, oauth2-proxy, Tailscale's `tailscale serve` with identity headers...) set
`RACKOON_FORWARD_AUTH_HEADER` (e.g. `Remote-User`) and `RACKOON_TRUSTED_PROXIES` to the proxy's address range; the header
is believed only from those addresses. `RACKOON_FORWARD_AUTH_USERS` limits which users it may name.

## Adding servers

Settings > Servers: add one by address, or import your `~/.ssh/config` (mount it read-only and set
`RACKOON_SSH_CONFIG`; ProxyJump entries are not supported). Rackoon signs in with a key it generates or one you import
(Settings > Keys), or with Tailscale SSH's `none` login. The first connection shows the server's host-key fingerprint
for you to compare; a key that changes later is blocked and never offered for acceptance.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `RACKOON_DATA` | `/data` | Everything Rackoon keeps: servers, trusted host keys, SSH keys, the admin password hash, alerts, notification settings. Folders 0700, files 0600. Back it up. |
| `RACKOON_ADMIN_PASSWORD_FILE` | unset | A file (Docker secret) with the admin password or its argon2id hash. |
| `RACKOON_TRUSTED_PROXIES` | unset | Comma-separated CIDRs whose `X-Forwarded-For` and forward-auth header are believed. |
| `RACKOON_FORWARD_AUTH_HEADER` | unset | The header a trusted proxy names the signed-in user in. Needs `RACKOON_TRUSTED_PROXIES`. |
| `RACKOON_FORWARD_AUTH_USERS` | any | Comma-separated users the header may name. |
| `RACKOON_SSH_CONFIG` | unset | An ssh_config file to import servers from. |
| `RACKOON_HOST`, `RACKOON_PORT` | `0.0.0.0`, `8080` | Where it listens inside the container. |
| `RACKOON_DEMO` | unset | `1` for demo mode. |

## What the image does to stay small and safe

- Runs as uid 10001 with no capabilities, and works with a read-only root file system and `no-new-privileges` (the
  compose files set all three); it only writes `/data` and `/tmp`.
- No pip, no setuid or setgid files, no shell tools added; a health check on `/api/health`.
- Every page has a strict Content-Security-Policy (scripts, styles and requests from its own origin only, no framing).
  Every change needs the CSRF header, a same-origin request and a JSON body; sign-in is rate-limited.
- Read-only is on for a new install and turns itself back on after 15 idle minutes.
- Sudo passwords are never stored: they are typed at sudo's own prompt for one action, or held in memory for 15
  minutes when you unlock Docker through sudo.
- Bind-mounting a host folder as `/data` instead of the named volume? Make it owned by 10001: `chown 10001:10001 <dir>`.

Releases: a `web-v*` tag publishes `ghcr.io/bgallagher/rackoon-web:<version>` for linux/amd64 and linux/arm64 with an
SBOM and build provenance (`latest` moves only for versions without a suffix).

## Upgrading and backups

`docker compose pull && docker compose up -d`. Everything lives in the `rackoon-data` volume; back it up like any other
volume (it holds private SSH keys, so keep the backup private).
