# Local TLS — valid certs for `*.homelab` and friends

Let's Encrypt can't issue for local names (no public DNS). The fix: **mkcert** — a local CA whose root you install on your devices, so `https://grafana.homelab` gets a real padlock with zero warnings.

## One-time CA setup (on your Windows machine)

```powershell
# install mkcert (winget)
winget install FiloSottile.mkcert

# create the local CA + install its root into Windows trust store
mkcert -install
```

This creates `rootCA.pem` in `mkcert -CAROOT` (usually `%LOCALAPPDATA%\mkcert`). **Copy that root CA to each device** (phone, laptop) and install it as a trusted CA — on Android: Settings → Security → Encryption → Install certificate → CA certificate.

## Issue a cert for your domains

```powershell
# from a machine that can reach node1 — cert covers these names
mkcert node1.homelab grafana.homelab npm.homelab 192.168.1.60
```

Produces `node1.homelab+2.pem` / `node1.homelab+2-key.pem`. For a wildcard covering everything under a domain, use a real domain you own instead — see "Public domain" below.

## Import into NPM

1. NPM admin (`:81`) → **SSL Certificates → Upload**
2. Certificate = the `.pem`, Private Key = the `-key.pem`
3. On each Proxy Host → **SSL** tab → select the cert → force SSL + HTTP/2

Certs are valid ~1 year (mkcert default); re-issue and re-upload when they expire.

## Public domain alternative (better long-term)

If you own any domain (even cheap), delegate a subdomain's DNS to a provider NPM supports (Cloudflare etc.) and use **DNS-01 challenge** — real Let's Encrypt certs, auto-renewing, no inbound ports needed. Works for names like `grafana.yourdomain.com` pointing at LAN IPs. This is the "proper" version of what mkcert approximates locally.

## Tailscale certs (remote access)

For tailnet access, `tailscale cert node1` issues real LE certs for `node1.<tailnet>.ts.net` — import those into NPM the same way, or access services directly over the tailnet IP.
