#!/usr/bin/env python3
"""Sync NPM proxy hosts from the declarative list below — idempotent.

NPM stores proxy hosts in its SQLite DB; this script is the git-managed
source of truth. Run on node1 after editing the list or .env:

    python3 node1/scripts/npm-sync.py

Requires NPM_API_TOKEN in node1/.env (NPM UI → User → Tokens → Create Token).
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
TOKEN = env.get("NPM_API_TOKEN") or os.environ.get("NPM_API_TOKEN")
if not TOKEN:
    sys.exit("NPM_API_TOKEN not set — create one in NPM UI → User → Tokens, add to node1/.env")

API = os.environ.get("NPM_API", "http://127.0.0.1:81/api")
NODE1_IP = env.get("NODE1_IP", "192.168.1.60")
NODE2_IP = env.get("NODE2_IP", "192.168.1.61")

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


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(r) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"NPM API {method} {path} → {e.code}: {e.read().decode()[:300]}")


existing = {d: h for h in req("GET", "/nginx/proxy-hosts") for d in h.get("domain_names", [])}

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
        req("PUT", f"/nginx/proxy-hosts/{host['id']}", host)
        print(f"updated  {domain} → http://{fhost}:{fport}")
    else:
        body = {
            **want,
            "certificate_id": 0,
            "ssl_forced": False,
            "http2_support": True,
            "hsts_enabled": False,
            "hsts_subdomains": False,
            "hsts_max_age": 0,
            "block_exploits": True,
            "advanced_config": "",
        }
        req("POST", "/nginx/proxy-hosts", body)
        print(f"created  {domain} → http://{fhost}:{fport}")

print("done — proxy hosts synced (http only)")
