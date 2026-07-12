#!/usr/bin/env bash
# upsmon NOTIFYCMD hook — pushes UPS power events to ntfy. Deployed to
# /etc/nut/ups-notify.sh by setup.sh; runs as the nut user with the event
# message as $1 and the event type in $NOTIFYTYPE. Reads its ntfy settings
# from /etc/nut/ups-notify.env (root:nut 640, rendered from ../.env).
set -u

[[ -f /etc/nut/ups-notify.env ]] && source /etc/nut/ups-notify.env
[[ -n "${NTFY_URL:-}" ]] || exit 0

msg="${1:-UPS event}"
case "${NOTIFYTYPE:-}" in
  ONBATT)   title="UPS on battery";               priority=urgent;  tags=battery,warning ;;
  LOWBATT)  title="UPS battery LOW";              priority=urgent;  tags=rotating_light ;;
  FSD)      title="UPS forced shutdown";          priority=urgent;  tags=rotating_light ;;
  SHUTDOWN) title="Server shutting down (UPS)";   priority=urgent;  tags=rotating_light ;;
  ONLINE)   title="UPS back on line power";       priority=default; tags=electric_plug ;;
  COMMBAD|NOCOMM) title="UPS communication lost"; priority=high;    tags=warning ;;
  COMMOK)   title="UPS communication restored";   priority=default; tags=white_check_mark ;;
  REPLBATT) title="UPS battery needs replacement"; priority=high;   tags=battery ;;
  *)        title="UPS event (${NOTIFYTYPE:-unknown})"; priority=default; tags=zap ;;
esac

args=(-fsS -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$msg")
[[ -n "${NTFY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
curl "${args[@]}" "$NTFY_URL/${NTFY_TOPIC:-server-ups}" >/dev/null 2>&1 || true
