#!/usr/bin/env bash
# Update homelab stacks — pulls pinned tags and recreates containers.
# NOT watchtower: you choose when. Check release notes BEFORE running,
# and take a ZFS snapshot / DB backup first on Node 2.
#
# Usage (run on the node, from the repo root):
#   ./scripts/update.sh node1
#   ./scripts/update.sh node2
#   ./scripts/update.sh all
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

update_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "no such directory: $dir" >&2; return 1
  fi
  if [[ -f "$dir/docker-compose.yml" ]]; then
    echo "==> $dir/docker-compose.yml"
    (cd "$dir" && docker compose pull && docker compose up -d)
  elif compgen -G "$dir/compose/*.yml" > /dev/null; then
    for f in "$dir"/compose/*.yml; do
      echo "==> $f"
      docker compose --env-file "$dir/.env" -f "$f" pull
      docker compose --env-file "$dir/.env" -f "$f" up -d
    done
  else
    echo "no compose files found in $dir" >&2; return 1
  fi
}

case "${1:-all}" in
  node1) update_dir "$ROOT/node1" ;;
  node2) update_dir "$ROOT/node2" ;;
  all)   update_dir "$ROOT/node1"; update_dir "$ROOT/node2" ;;
  *)     echo "usage: $0 [node1|node2|all]" >&2; exit 1 ;;
esac

echo
echo "Update complete. Check release notes for breaking changes, then verify:"
echo "  docker compose ps        # per stack directory"
echo "  docker logs <container>  # if something looks off"
