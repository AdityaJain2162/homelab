#!/usr/bin/env bash
# Generate a self-signed TLS cert for the Vault listener (API + UI on :8200).
# Validity: 10 years. Re-run if SANs change (node IP / names) or to rotate.
# Usage: bash node1/scripts/vault-tls.sh [node-ip]   (default 192.168.1.60)
set -euo pipefail

TLS_DIR="${TLS_DIR:-/opt/docker/appdata/vault/tls}"
IP="${1:-192.168.1.60}"

sudo mkdir -p "$TLS_DIR"
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TLS_DIR/vault.key" -out "$TLS_DIR/vault.crt" \
  -subj "/CN=vault.homelab/O=homelab" \
  -addext "subjectAltName=DNS:vault.homelab,DNS:node1.homelab,IP:${IP}"
sudo chmod 600 "$TLS_DIR/vault.key"
sudo chmod 644 "$TLS_DIR/vault.crt"
# container runs as uid 100 — it must be able to read the certs
sudo chown 100:1000 "$TLS_DIR/vault.key" "$TLS_DIR/vault.crt"

echo "TLS cert written to $TLS_DIR"
echo "Restart Vault to pick it up:  docker compose restart vault"
