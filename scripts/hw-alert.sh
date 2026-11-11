#!/usr/bin/env bash
# Hardware alert dispatcher — invoked by smartd (-M exec) with the alert
# on stdin. Forwards it to Telegram and/or Discord.
#
# Credentials live OUTSIDE the repo in /etc/homelab-alert.env (root:root 600),
# deployed by the ansible hardware_monitor role:
#   TELEGRAM_BOT_TOKEN=...   # from @BotFather
#   TELEGRAM_CHAT_ID=...     # your chat/channel id
#   DISCORD_WEBHOOK_URL=...  # channel → Integrations → Webhooks
#
# Always exits 0 — an alerting failure must never wedge smartd.
set -uo pipefail

ENV_FILE=/etc/homelab-alert.env
if [[ -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -z "${TELEGRAM_CHAT_ID:-}" && -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "hw-alert: no alert targets configured ($ENV_FILE)" >&2
  exit 0
fi

HOST="$(hostname -s 2>/dev/null || hostname)"
MSG="$(head -c 3500)"   # stdin = smartd alert; cap under Telegram's 4096 limit
TEXT="**[$HOST] SMART/hardware alert**

${MSG}"

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  curl -fsS -m 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TEXT}" >/dev/null 2>&1 || \
    echo "hw-alert: telegram send failed" >&2
fi

if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
  jq -n --arg c "$TEXT" '{content: $c}' | \
    curl -fsS -m 10 -H 'Content-Type: application/json' -d @- \
    "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || \
    echo "hw-alert: discord send failed" >&2
fi

exit 0
