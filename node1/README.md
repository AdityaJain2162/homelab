# Node 1 — Infrastructure

Always-on box: DNS, reverse proxy, remote access, home automation, alerting. Must keep working when Node 2 is off.

## Hardware

| Item | Spec |
|---|---|
| Board | ASUS M5A78L-M LX V2 |
| CPU | AMD Athlon II X2 270 (2C/2T, 3.4 GHz) — **no AVX, no AES-NI, no iGPU** |
| RAM | 8 GB DDR3 |
| Boot drive | 256 GB SATA SSD |
| HDDs | 3× 1 TB SATA — owned but **not installed**; will move to Node 2 for the ZFS pool |
| SATA ports | 6 total (1 used by the SSD; 5 free — room for a future backup drive) |
| Network | 1 GbE, wired only |

## OS

**Ubuntu Server 26.04 LTS "Resolute"** — install once, don't touch.

- Server install — **minimal preferred, standard works fine**. ext4 on the whole 256 GB SSD, **no LVM**, OpenSSH enabled.
- If you installed the **standard** image, disable the extras you don't need (saves RAM on 8 GB):

  ```bash
  sudo systemctl disable --now ModemManager.service multipathd.service open-iscsi.service fwupd.service 2>/dev/null
  sudo apt purge -y landscape-client ubuntu-advantage-tools 2>/dev/null
  sudo snap list    # remove snaps you don't want
  ```
- 26.04 notes: `sudo` is sudo-rs, cgroup v2 only, kernel 7.0.
- Docker comes from Docker's official apt repo — `resolute` is supported:

```bash
sudo apt update && sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu resolute stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out and back in
```

Post-install basics:

```bash
sudo apt full-upgrade -y
sudo timedatectl set-timezone Asia/Kolkata
sudo systemctl edit --force --full systemd-journald   # cap journal at ~1 GB (optional)
```

Give Node 1 a **static IP or DHCP reservation** on the router — everything points at it.

## Services

| Service | Image (pinned) | Port(s) | Purpose |
|---|---|---|---|
| AdGuard Home | `adguard/adguardhome:v0.107.80` | 53, 3000 | Network DNS + ad blocking |
| Nginx Proxy Manager | `jc21/nginx-proxy-manager:2.16.0` | 80, 443, 81 | Reverse proxy + TLS |
| Home Assistant | `ghcr.io/home-assistant/home-assistant:2026.11.1` | 8123 | Home automation (host network for discovery) |
| Mosquitto | `eclipse-mosquitto:2.1.2-alpine` | 1883, 9001 | MQTT broker — also used by Frigate on Node 2 |
| Uptime Kuma | `louislam/uptime-kuma:2.5.9` | 3001 | Uptime monitoring/alerting |
| Tailscale | `tailscale/tailscale:v1.104.5` | — | Mesh VPN / remote access |
| Node Exporter | `quay.io/prometheus/node-exporter:v1.12.1` | 9100 | Metrics → VictoriaMetrics on Node 2 |
| Zigbee2MQTT | *(commented out)* | 8099 | Enable when the USB dongle arrives |
| Asterisk PBX | *(planned — commented out)* | 5060 + RTP | SIP intercom + trunk — see [`docs/voice.md`](../docs/voice.md) |

Host-level (installed by the Ansible `hardware_monitor` role, not compose): **smartmontools/smartd** watches all drives — short self-test Sun 02:00, long monthly — and alerts via `scripts/hw-alert.sh` to Telegram/Discord (targets in `/etc/homelab-alert.env`). **node-exporter** exposes SMART attributes + temps as metrics for Grafana history/alerting on Node 2.

## Deploy

**Automated (recommended) — Ansible:**

```bash
cd ansible
ansible-playbook site.yml --limit node1    # Docker, repo, timer, dirs, Mosquitto, compose up
```

Or the standalone script (does the same minus Ansible):

```bash
bash scripts/bootstrap.sh    # idempotent — Docker, dirs, .env, Mosquitto creds, compose up
```

**Manual equivalent:**

```bash
cd node1
cp .env.example .env          # edit TZ etc. if needed

# 1. Create state dirs
sudo mkdir -p /opt/docker/appdata/{adguardhome/{work,conf},npm,homeassistant,mosquitto/{config,data,log},uptime-kuma,tailscale}
sudo chown -R 1000:1000 /opt/docker/appdata   # PUID/PGID=1000; harmless for images that ignore it

# 2. Mosquitto credentials (MQTT user for Zigbee2MQTT + Frigate)
docker run --rm -v /opt/docker/appdata/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.1.2-alpine mosquitto_passwd -c /mosquitto/config/passwordfile <mqtt-user>
# copy config/mosquitto/mosquitto.conf into /opt/docker/appdata/mosquitto/config/

# 3. Start
docker compose up -d
docker compose ps
```

## Configuration variables (`.env`)

| Variable | Purpose |
|---|---|
| `PUID` / `PGID` / `TZ` | Container user/group + timezone (1000 / Asia/Kolkata) |
| `NODE1_NAME` / `NODE1_IP` | Hostname (Tailscale) + LAN IP on the Management VLAN |
| `LAN_SUBNET` | Management VLAN subnet — documentation/planning |
| `TS_AUTHKEY` | Optional Tailscale headless auth key |
| `MQTT_USER` / `MQTT_PASSWORD` | Mosquitto credentials — source of truth reused by Node 2 services |

## Post-setup checklist

1. **AdGuard** → http://node1:3000 — run the wizard, set web port to **3000** (NPM owns :80). This is the **primary** of two DNS instances (Node 2 runs the secondary — see `node2/compose/dns.yml`). Configure:
   - **Upstream:** DNS settings → add `https://dns.cloudflare.com/dns-query` (DoH — encrypted hop upstream).
   - **Blocklists:** Filters → DNS blocklists → add custom lists:
     - `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt` — HaGeZi Multi Pro
     - `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt` — HaGeZi TiF threat intel (malware/phishing add-on, pairs with any tier)
     (If jsdelivr ever fails, `raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt` is the direct source.)
   - **DNS rewrites:** `node1.homelab` → `NODE1_IP`, `node2.homelab` → `NODE2_IP` (values from `.env`) — gives the LAN friendly names; the IPs stay the source of truth for bootstrap/Ansible.
   - Then **export `AdGuardHome.yaml`** (Settings → export) and import it on Node 2's instance so both serve identical answers.
   - On the router set DHCP DNS to **Node 1 (primary) + Node 2 (secondary)**; keep the router's own upstream DNS as fallback so DNS survives both nodes.
2. **NPM** → http://node1:81 — default admin `admin@example.com` / `changeme` (change immediately). Use it for friendly hostnames + Let's Encrypt TLS on Node 1 apps.
3. **Home Assistant** → http://node1:8123 — onboarding wizard.
4. **Tailscale** → authenticate once:
   `docker compose exec tailscale tailscale up` (prints a login URL), or set `TS_AUTHKEY` in `.env` for headless auth.
5. **Uptime Kuma** → http://node1:3001 — create admin, add monitors (router, Node 2 services once they exist), configure a push channel (Telegram/ntfy/email).
6. **Mosquitto** — credentials created above are used by Zigbee2MQTT (here) and Frigate (Node 2 → `mqtt://$NODE1_IP:1883`, value from `.env`).

## Enabling Zigbee2MQTT (when the dongle arrives)

1. Plug in the coordinator (short USB extension recommended).
2. Find its stable path: `ls -l /dev/serial/by-id/` on the host.
3. Uncomment the `zigbee2mqtt` block in `docker-compose.yml`, set the `devices:` path, pin the image tag, set `MQTT_USER`/`MQTT_PASSWORD` in `.env`, then `docker compose up -d`.

## Caveats

- **No AVX** — most images run fine, but if a container crash-loops check `docker logs <name>` first; anything needing AVX (e.g. MongoDB 8 / Omada) belongs on Node 2.
- Do **not** put ZFS or bulk storage here — the 3 HDDs are installed in Node 2 and the pool created there fresh.
- Optional future role: backup target. With free SATA ports, a drive added later can hold restic/borg copies of Node 2's photos/shares.
