#!/usr/bin/env python3
"""Sync NPM proxy hosts from the declarative list below — idempotent.

NPM stores proxy hosts in its SQLite DB; this script is the git-managed
source of truth. Run on node1 after editing the list or .env:

    python3 node1/scripts/npm-sync.py

Auth: set NPM_USER + NPM_PASSWORD in node1/.env (the script mints a session
token itself), or supply NPM_API_TOKEN directly.
HTTP only — SSL/cert fields are left untouched on update so future certs survive.
"""
import json
import os
import sys
import urllib.error
import urllib.request

NODE1_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env


env = load_env(os.path.join(NODE1_DIR, ".env"))
API = os.environ.get("NPM_API", "http://127.0.0.1:81/api")
NODE1_IP = env.get("NODE1_IP", "192.168.1.60")
NODE2_IP = env.get("NODE2_IP", "192.168.1.61")


def req(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"NPM API {method} {path} → {e.code}: {e.read().decode()[:300]}")


# Auth: NPM_API_TOKEN if present, else mint a session token from NPM_USER/NPM_PASSWORD
TOKEN = env.get("NPM_API_TOKEN") or os.environ.get("NPM_API_TOKEN")
if not TOKEN:
    user = env.get("NPM_USER") or os.environ.get("NPM_USER")
    password = env.get("NPM_PASSWORD") or os.environ.get("NPM_PASSWORD")
    if not (user and password):
        sys.exit("Set NPM_USER + NPM_PASSWORD (or NPM_API_TOKEN) in node1/.env")
    TOKEN = req("POST", "/tokens", {"identity": user, "secret": password})["token"]

# domain | forward_host | forward_port — container names resolve via Docker DNS;
# host-networked AdGuard needs the host IP instead.
RAW_HOSTS = [
    "grafana.homelab|grafana|3000",
    "home.homelab|homepage|3000",
    "homeassistant.homelab|homeassistant|8123",
    "vm.homelab|victoria-metrics|8428",
    "adguard.homelab|" + NODE1_IP + "|3000",
    "immich.homelab|" + NODE2_IP + "|2283",   # Node 2 — 502s until it exists
]


existing = {d: h for h in req("GET", "/nginx/proxy-hosts", token=TOKEN) for d in h.get("domain_names", [])}

for entry in RAW_HOSTS:
    domain, fhost, fport = entry.split("|")
    want = {
        "domain_names": [domain],
        "forward_scheme": "http",
        "forward_host": fhost,
        "forward_port": int(fport),
    }
    if domain in existing:
        host = existing[domain]
        host.update(want)
        req("PUT", f"/nginx/proxy-hosts/{host['id']}", host, token=TOKEN)
        print(f"updated  {domain} → http://{fhost}:{fport}")
    else:
        body = {
            **want,
            "access_list_id": 0,
            "certificate_id": 0,
            "meta": {"letsencrypt_agree": False, "dns_challenge": False},
            "advanced_config": "",
            "locations": [],
            "block_exploits": True,
            "caching_enabled": False,
            "allow_websocket_upgrade": True,
            "http2_support": True,
            "hsts_enabled": False,
            "hsts_subdomains": False,
            "ssl_forced": False,
        }
        req("POST", "/nginx/proxy-hosts", body, token=TOKEN)
        print(f"created  {domain} → http://{fhost}:{fport}")

print("done — proxy hosts synced (http only)")
