#!/usr/bin/env bash
# Unseal Vault after a container/host restart.
# Reads the unseal key from ~/.vault-unseal-key (chmod 600, never commit).
# If you used Shamir shares >1, this only works for threshold=1 — otherwise
# run: docker compose exec vault vault operator unseal   (interactive).
set -euo pipefail

KEY_FILE="${VAULT_UNSEAL_KEY_FILE:-$HOME/.vault-unseal-key}"
[[ -f "$KEY_FILE" ]] || {
  echo "ERROR: $KEY_FILE not found." >&2
  echo "Run 'docker compose exec vault vault operator init' first and save a key there." >&2
  exit 1
}

docker exec vault vault operator unseal "$(cat "$KEY_FILE")" | grep -E 'Sealed|HA Enabled'
