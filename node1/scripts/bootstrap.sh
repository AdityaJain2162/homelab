#!/usr/bin/env bash
# Node 1 bootstrap — Ubuntu Server 26.04 → running homelab stack.
# Idempotent: safe to re-run. Run as your normal sudo user:
#   bash scripts/bootstrap.sh
set -euo pipefail

APPDATA=/opt/docker/appdata
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # node1/

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }

# ---------- 0. sanity ----------
if [[ $EUID -eq 0 ]]; then
  warn "don't run as root — run as your user (the script uses sudo internally)"; exit 1
fi
if ! grep -qi ubuntu /etc/os-release; then
  warn "this script targets Ubuntu Server (26.04)"; exit 1
fi
if ! sudo -n true 2>/dev/null && ! sudo -v; then
  warn "sudo access required"; exit 1
fi

# ---------- 1. base packages ----------
info "base packages"
sudo apt update
sudo apt install -y ca-certificates curl git

# ---------- 2. Docker (official repo — resolute is supported) ----------
if command -v docker >/dev/null 2>&1; then
  info "docker already installed: $(docker --version)"
else
  info "installing Docker Engine + Compose plugin"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu resolute stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if ! groups "$USER" | grep -qw docker; then
  info "adding $USER to docker group"
  sudo usermod -aG docker "$USER"
  warn "log out and back in (or run: newgrp docker) before the compose step"
fi

if ! docker ps >/dev/null 2>&1; then
  warn "docker not usable yet — re-login for the docker group, then re-run this script"; exit 1
fi

# ---------- 3. journal size cap (~500 MB) ----------
if [[ ! -f /etc/systemd/journald.conf.d/size.conf ]]; then
  info "capping systemd journal at 500 MB"
  sudo mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=500M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf >/dev/null
  sudo systemctl restart systemd-journald
fi

# ---------- 3b. free port 53 for AdGuard (systemd-resolved stub) ----------
if ! grep -rq 'DNSStubListener=no' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/ 2>/dev/null; then
  info "disabling systemd-resolved stub listener (frees :53 for AdGuard)"
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf >/dev/null
  sudo systemctl restart systemd-resolved
fi

# ---------- 3c. forwarding + ip_tables (Tailscale subnet router) ----------
# Docker enables ip_forward at runtime anyway; persisting keeps the node
# routing LAN_SUBNET → tailnet even if Docker isn't running yet. The tailscale
# container also needs the legacy ip_tables module — it ships iptables-legacy
# but Ubuntu runs nftables, and module loading requires CAP_SYS_MODULE (not
# granted), so the host loads it and every netns gets the filter table.
if [[ ! -f /etc/sysctl.d/99-ip-forward.conf ]]; then
  info "enabling net.ipv4.ip_forward (Tailscale subnet router)"
  printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' | sudo tee /etc/sysctl.d/99-ip-forward.conf >/dev/null
  sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf >/dev/null
fi
if [[ ! -f /etc/modules-load.d/tailscale.conf ]]; then
  info "loading ip_tables/ip6_tables (tailscaled legacy netfilter)"
  printf 'ip_tables\nip6_tables\n' | sudo tee /etc/modules-load.d/tailscale.conf >/dev/null
  sudo modprobe ip_tables
  sudo modprobe ip6_tables || true   # no v6 filter on kernels w/o ip6_tables
fi

# ---------- 4. state dirs (container PUID/PGID = 1000) ----------
info "creating state dirs under $APPDATA"
sudo mkdir -p "$APPDATA"/{adguardhome/{work,conf},npm,homeassistant,mosquitto/{config,data,log},tailscale,victoria-metrics,grafana}
sudo chown -R 1000:1000 "$APPDATA"
sudo chown -R 472:472 "$APPDATA/grafana"   # grafana image runs as uid 472

# ---------- 5. .env ----------
if [[ ! -f "$STACK_DIR/.env" ]]; then
  cp "$STACK_DIR/.env.example" "$STACK_DIR/.env"
  warn "created $STACK_DIR/.env — review it (TZ etc.)"
else
  info ".env already exists — leaving it untouched"
fi

# ---------- 6. Mosquitto config + credentials ----------
MQTT_CONF="$APPDATA/mosquitto/config"
if [[ ! -f "$MQTT_CONF/mosquitto.conf" ]]; then
  info "installing mosquitto.conf"
  sudo cp "$STACK_DIR/config/mosquitto/mosquitto.conf" "$MQTT_CONF/mosquitto.conf"
  sudo chown 1000:1000 "$MQTT_CONF/mosquitto.conf"
fi
if [[ ! -f "$MQTT_CONF/passwordfile" ]]; then
  read -rp "MQTT username (for Zigbee2MQTT + Frigate): " mqtt_user
  docker run --rm -v "$MQTT_CONF:/mosquitto/config" \
    eclipse-mosquitto:2.1.2-alpine mosquitto_passwd -c /mosquitto/config/passwordfile "$mqtt_user"
  info "mqtt user '$mqtt_user' created — reuse this password for Zigbee2MQTT and Frigate"
fi

# ---------- 6b. Home Assistant seed config ----------
# HA >= 2026.x migrates the http: yaml block into .storage on FIRST boot —
# seeding here means trusted_proxies lands before the migration runs.
HA_CONF="$APPDATA/homeassistant/configuration.yaml"
if [[ ! -f "$HA_CONF" ]]; then
  info "seeding HA configuration.yaml (trusted_proxies for NPM)"
  sudo cp "$STACK_DIR/config/homeassistant/configuration.yaml" "$HA_CONF"
  sudo chown 1000:1000 "$HA_CONF"
fi

# ---------- 6c. AdGuard config (seeding skips the setup wizard) ----------
# Template ships upstreams, blocklists, and *.homelab rewrites — all that
# remains is the admin password hash and the node IPs from .env.
AGH_CONF="$APPDATA/adguardhome/conf/AdGuardHome.yaml"
if [[ ! -f "$AGH_CONF" ]]; then
  read -rsp "AdGuard admin password (web UI): " agh_pass; echo
  info "generating bcrypt hash + seeding AdGuardHome.yaml"
  agh_hash="$(docker run --rm httpd:2.4-alpine htpasswd -nbB admin "$agh_pass" | tr -d ':\n')"
  agh_n1="$(awk -F= '/^NODE1_IP=/ {gsub(/["'"'"' ]/,"",$2); print $2; exit}' "$STACK_DIR/.env")"
  agh_n2="$(awk -F= '/^NODE2_IP=/ {gsub(/["'"'"' ]/,"",$2); print $2; exit}' "$STACK_DIR/.env")"
  sudo sed -e "s|\\\$2y\\\$10\\\$REPLACE_WITH_BCRYPT_HASH_FROM_HTPASSWD|${agh_hash}|" \
           -e "s|192.168.1.60|${agh_n1:-192.168.1.60}|g" \
           -e "s|192.168.1.61|${agh_n2:-192.168.1.61}|g" \
           "$STACK_DIR/config/adguard/AdGuardHome.yaml" | sudo tee "$AGH_CONF" >/dev/null
  sudo chown 1000:1000 "$AGH_CONF"
fi

# ---------- 7. compose ----------
info "pulling images and starting stack"
cd "$STACK_DIR"
docker compose pull
docker compose up -d
docker compose ps

# ---------- 7b. NPM proxy hosts (idempotent sync via API) ----------
if grep -qE '^NPM_(USER|PASSWORD)=' "$STACK_DIR/.env" 2>/dev/null; then
  info "syncing NPM proxy hosts (scripts/npm-sync.py)"
  python3 "$STACK_DIR/scripts/npm-sync.py" \
    || warn "npm-sync failed — run it manually once NPM is reachable on :81"
else
  warn "NPM_USER/NPM_PASSWORD not in .env — skipping npm-sync (proxy hosts)"
fi

# ---------- 8. next steps ----------
node1_ip="$(grep -E '^NODE1_IP=' "$STACK_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | awk '{print $1}' | tr -d "\"'" || true)"
node1_ip="${node1_ip:-<set NODE1_IP in .env>}"

cat <<'EOF' | sed "s|<node1-ip>|${node1_ip}|g"

============================================================
 Bootstrap complete. Remaining manual steps:

   AdGuard Home : http://<node1-ip>:3000   (already configured — login with
                  the password you just set; rewrites + blocklists are live)
   Nginx Proxy M.: http://<node1-ip>:81    (default admin: admin@example.com /
                  changeme — change it; proxy hosts synced by npm-sync.py)
   Home Assistant: http://<node1-ip>:8123  (onboarding wizard)
   Homepage     : http://<node1-ip>:3003   (or http://home.homelab once DNS is up)

   Tailscale    : docker logs tailscale → open the auth URL it prints
                  (or set TS_AUTHKEY in .env to skip this)
   Router       : set DHCP DNS → this node's IP (keep router DNS as fallback)

   Zigbee2MQTT  : uncomment its block in docker-compose.yml once the dongle arrives
============================================================
EOF
