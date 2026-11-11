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

# ---------- 4. state dirs (container PUID/PGID = 1000) ----------
info "creating state dirs under $APPDATA"
sudo mkdir -p "$APPDATA"/{adguardhome/{work,conf},npm,homeassistant,mosquitto/{config,data,log},uptime-kuma,tailscale}
sudo chown -R 1000:1000 "$APPDATA"

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

# ---------- 7. compose ----------
info "pulling images and starting stack"
cd "$STACK_DIR"
docker compose pull
docker compose up -d
docker compose ps

# ---------- 8. next steps ----------
node1_ip="$(grep -E '^NODE1_IP=' "$STACK_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | awk '{print $1}' | tr -d "\"'" || true)"
node1_ip="${node1_ip:-<set NODE1_IP in .env>}"

cat <<'EOF' | sed "s|<node1-ip>|${node1_ip}|g"

============================================================
 Bootstrap complete. Next steps:

   AdGuard Home : http://<node1-ip>:3000   (wizard → set web port 3000)
   Nginx Proxy M.: http://<node1-ip>:81    (default admin: admin@example.com / changeme)
   Home Assistant: http://<node1-ip>:8123
   Uptime Kuma  : http://<node1-ip>:3001

   Tailscale    : docker compose exec tailscale tailscale up
   Router       : set DHCP DNS → this node's IP (keep router DNS as fallback)

   Zigbee2MQTT  : uncomment its block in docker-compose.yml once the dongle arrives
============================================================
EOF
