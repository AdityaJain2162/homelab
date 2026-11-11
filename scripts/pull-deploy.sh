#!/usr/bin/env bash
# Pull-based deploy: git pull --ff-only + docker compose up for this node's stack(s).
# Installed as a systemd timer by ansible (roles/node_deploy) — runs every 6h.
#
# Safety properties:
#   - .env is gitignored → secrets on the node are never touched by git
#   - --ff-only refuses force-pushes/history rewrites instead of clobbering state
#   - stacks without .env are skipped (node2 drafts stay off until configured)
#   - pinned image tags mean `compose pull` only fetches what tags actually moved
#
# Usage (manual trigger): pull-deploy.sh <node1|node2|all>
set -euo pipefail

STACK="${1:?usage: $0 <node1|node2|all>}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

cd "$REPO_DIR"
git fetch --prune origin
git pull --ff-only

deploy_dir() {
  local dir="$1" f ok=0
  if [[ ! -f "$dir/.env" ]]; then
    echo "skip $dir — no .env (copy .env.example and fill it in)"
    return 0
  fi
  if [[ -f "$dir/docker-compose.yml" ]]; then
    echo "==> $dir/docker-compose.yml"
    if ! (cd "$dir" && docker compose pull && docker compose up -d); then
      echo "FAILED: $dir" >&2
      ok=1
    fi
  else
    for f in "$dir"/compose/*.yml; do
      [[ -e "$f" ]] || continue
      echo "==> $f"
      if ! docker compose --env-file "$dir/.env" -f "$f" pull \
        || ! docker compose --env-file "$dir/.env" -f "$f" up -d; then
        echo "FAILED: $f" >&2
        ok=1
      fi
    done
  fi
  return "$ok"
}

rc=0
case "$STACK" in
  node1) deploy_dir node1 || rc=$? ;;
  node2) deploy_dir node2 || rc=$? ;;
  all)   deploy_dir node1 || rc=$?; deploy_dir node2 || rc=$? ;;
  *)     echo "usage: $0 <node1|node2|all>" >&2; exit 1 ;;
esac

if [[ $rc -eq 0 ]]; then
  echo "deploy OK ($STACK)"
else
  echo "deploy finished with failures ($STACK) — check: journalctl -u homelab-deploy.service" >&2
fi
exit "$rc"
