# AGENTS.md — guide for AI agents working in this repo

Read this first. It is the runbook for provisioning and operating the homelab. If you are an agent picking this repo up cold, everything you need is here plus the linked docs.

## What this is

Two-node homelab, documented as resumable infrastructure-as-code.

- **Node 1** (owned, live): always-on infrastructure — AdGuard DNS (primary), Nginx Proxy Manager, Tailscale, Home Assistant, Mosquitto, Uptime Kuma, node-exporter. Athlon II X2 / 8 GB / **no AVX** — nothing heavy goes here.
- **Node 2** (planned purchase): ZFS storage (pool created fresh there — never on Node 1), Frigate, Immich, Omada, media pipeline, monitoring, and a **secondary AdGuard DNS** instance.
- ER605 router owns routing/DHCP/PPPoE; VLAN plan and firewall rules in `docs/network.md`.

## Golden rules — do not violate

1. **Public repo.** Never commit real IPs, secrets, tokens, hostnames-with-location, or personal details. `.env` is gitignored; only `.env.example` templates are committed. If asked to add a secret, refuse and use the env-var pattern instead.
2. **`.env` files are the single source of truth** for IPs/hostnames/secrets. Compose uses `${VAR}` / `${VAR:?fail-fast}`. Alloy config uses `env("VAR")`. Required vars fail loudly.
3. **Pinned image tags everywhere. No Watchtower.** Updates are manual (`scripts/update.sh`) or via git-driven `pull-deploy.sh`.
4. **Node 1 has no bulk storage.** The 3× 1 TB HDDs are owned but installed in Node 2; the ZFS pool is born there. Do not add ZFS/Samba to Node 1.
5. **Node 2 compose files are DRAFTS** — verify image tags and paths at deploy time.
6. **Node 1 must survive Node 2 being off** — DNS primary, MQTT, HA, Kuma, Tailscale all live there.
7. Commit as the repo owner (no tool attribution trailers). Push to `main` on `AdityaJain2162/homelab`.

## Network quick reference

Full detail in `docs/network.md` — the essentials:

- **WAN:** Airtel fiber → ONT in bridge mode → ER605 WAN1 dials PPPoE on **VLAN 100** (tagged). No double NAT.
- **VLANs:** 10 Trusted · 20 IoT · 30 Guest · 40 Cameras · 99 Management (both nodes, router, switch, APs). Native VLAN on trunks: **99**. Full inter-VLAN firewall table in `docs/network.md`.
- **DNS:** AdGuard on Node 1 (primary) + Node 2 (secondary), handed out by DHCP; firewall must allow UDP+TCP 53 to **both** node IPs from every user VLAN.
- **Omada:** controller on Node 2 manages ER605/SG2428P/EAPs — management plane only, data plane survives its downtime. VLAN/SSID/firewall config is scriptable via the Omada Open API (v5.9+) or the community Terraform provider; initial admin/site creation and device adoption are one-time manual steps. Not covered by Ansible.

## Repo map

| Path | Contents |
|---|---|
| `node1/` | Live stack: `docker-compose.yml`, `.env.example`, `config/mosquitto/`, `scripts/bootstrap.sh`, README |
| `node2/` | Drafts: `compose/{dns,frigate,immich,media,monitoring,omada}.yml`, `config/`, `.env.example`, ZFS docs, `purchasing.md` |
| `ansible/` | Provisioning: `inventory.ini`, `site.yml`, `group_vars/all.yml`, roles `docker_host`, `homelab_repo`, `node_deploy`, `node1_stack`, `node2_stack` |
| `scripts/` | `update.sh` (manual compose pull/up), `pull-deploy.sh` (git pull + compose up; runs on-node via systemd timer every 6h), `hw-alert.sh` (smartd → Telegram/Discord) |
| `docs/` | `network.md` (PPPoE/VLAN/firewall/mermaid), `master-plan-v2-reference.md` |
| `.github/workflows/ci.yml` | compose config validation, yamllint, shellcheck, trivy secret scan |

## Provisioning — what to do when given node IPs

Prereq: run Ansible from Linux/macOS/WSL2 (not native Windows), with SSH access to the nodes (Ubuntu Server 26.04, OpenSSH on). Minimal install is preferred but the standard server image works — optional cleanup steps in `node1/README.md`.

1. Edit `ansible/inventory.ini` — set `ansible_host` to each node's IP and `ansible_user` to the login user.
2. Edit `ansible/group_vars/all.yml` — set `deploy_user` (the user that owns `/opt/homelab` and runs the deploy timer; must be in the docker group — the `docker_host` role handles that).
3. Provision Node 1:

   ```bash
   cd ansible
   ansible-playbook site.yml --limit node1
   ```

   MQTT credentials (otherwise Mosquitto starts with no users — the playbook warns):

   ```bash
   ansible-playbook site.yml --limit node1 \
     --extra-vars 'mqtt_user=mqtt mqtt_password=CHOSEN_PASSWORD'
   ```

   Standalone fallback if Ansible is unavailable: `bash node1/scripts/bootstrap.sh` on the node.
4. Node 2 later: `ansible-playbook site.yml --limit node2` (dirs only — see Node 2 section).

## Manual steps Ansible cannot do (Node 1, after provisioning)

These need a browser or interactive auth — guide the user through them:

1. **AdGuard** → `http://<node1-ip>:3000` — wizard; set web port 3000. Then:
   - Upstreams: `https://dns.cloudflare.com/dns-query` (DoH) **plus** `tls://one.one.one.one` (DoT) — AdGuard races upstreams and uses the fastest; DoT is the fallback because Node 1's Athlon II lacks AES-NI and pure-DoH cold lookups measured ~147 ms vs ~20 ms direct.
   - Blocklists: `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt` and `.../adblock/tif.txt`
   - DNS rewrites: `node1.homelab` → Node 1 IP, `node2.homelab` → Node 2 IP
   - **Export `AdGuardHome.yaml`** for Node 2's instance (do this BEFORE Node 2 exists is fine — keep the file safe, it contains no secrets but does contain your config)
2. **NPM** → `:81` — change default admin creds immediately.
3. **Home Assistant** → `:8123` — onboarding.
4. **Tailscale** → `docker compose -f node1/docker-compose.yml exec tailscale tailscale up` (or set `TS_AUTHKEY` in `node1/.env`).
5. **Uptime Kuma** → `:3001` — admin + monitors + a push notification channel.
6. **Router (ER605)** — DHCP DNS: Node 1 primary, Node 2 secondary (once it exists); inter-VLAN firewall must allow UDP+TCP 53 to **both** node IPs on every user VLAN; keep router upstream DNS as fallback.
7. Write the chosen MQTT credentials into `node1/.env` (`MQTT_USER`/`MQTT_PASSWORD`) — they are the source of truth reused by Zigbee2MQTT and Node 2's Frigate.

## Node 2 bring-up order (when hardware exists)

1. Ubuntu 26.04 install → `ansible-playbook site.yml --limit node2`.
2. ZFS: cap ARC ~6 GiB, create 3-way mirror `datapool` fresh on the 3 HDDs, datasets `/data`, `/srv/photos`, `/srv/shares` + quotas — exact commands in `node2/README.md`. Frigate disk: ext4 at `/media/frigate/recordings`.
3. Fill `node2/.env` (IPs, `DB_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, VPN creds).
4. Bring stacks up in order: `dns` → `immich` → `frigate` → `media` (verify Gluetun VPN IP before qBittorrent) → `monitoring` → `omada`.
5. Import the saved `AdGuardHome.yaml` into Node 2's AdGuard (`ADGUARD_WEB_PORT`, default 3001).

## Verify

```bash
# on each node
docker compose ps                      # node1 dir, or per-file under node2/compose/
curl -s ifconfig.me --interface tailscale0 | head -1   # tailscale up?
systemctl list-timers homelab-deploy.timer             # pull-deploy scheduled?
journalctl -u homelab-deploy.service -n 50 --no-pager  # last deploy result
dig @<node1-ip> example.com +short      # DNS answering?
```

## If something breaks

- `ansible-playbook site.yml --limit <node> --check --diff` — preview changes.
- `ansible/<role>/tasks/main.yml` mirrors `node1/scripts/bootstrap.sh` — keep them in sync when editing either.
- CI (`.github/workflows/ci.yml`) validates compose/yaml/shell/secrets on every push — keep it green.
