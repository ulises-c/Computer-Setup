#!/usr/bin/env bash
set -euo pipefail

# Apply the CUPS host access policy from .env to /etc/cups/cupsd.conf.
#
# Why this exists: the Pi's CUPS shares a USB printer to (a) family devices on
# the home LAN over Bonjour and (b) the operator's devices via the Tailscale
# HTTPS sidecar. That means cupsd must accept a specific set of Host names
# (ServerAlias) and allow a specific set of sources (<Location />), and those
# values — the LAN subnet, the Pi's hostname, the tailnet name — are private, so
# they live in a gitignored .env instead of being hardcoded in this public repo.
# See README.md for the full rationale.
#
# Idempotent: re-running rewrites the ServerAlias line and the root <Location />
# Allow rules to match .env exactly. Everything else in cupsd.conf is untouched.
#
# Usage:
#   bash setup.sh --dry-run     # show the diff + validate, change nothing
#   sudo bash setup.sh          # apply, validate, restart cups.service

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DRY_RUN=false
CUPSD_CONF="${CUPSD_CONF:-/etc/cups/cupsd.conf}"

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

[[ -f "$SCRIPT_DIR/.env" ]] || {
  printf 'error: create %s/.env from .env.example first\n' "$SCRIPT_DIR" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

: "${CUPS_SERVER_ALIAS:?set CUPS_SERVER_ALIAS in .env (space-separated Host names; never \"*\")}"
: "${CUPS_ALLOW_FROM:?set CUPS_ALLOW_FROM in .env (space-separated sources; never \"all\")}"

# Enforce the repo's hard rule in code: no wildcards. Word-splitting on the
# space-separated token lists is intentional here.
# shellcheck disable=SC2086
for a in $CUPS_SERVER_ALIAS; do
  [[ "$a" == "*" ]] && { printf 'error: refusing ServerAlias "*" (DNS-rebind hole)\n' >&2; exit 1; }
done
# shellcheck disable=SC2086
for s in $CUPS_ALLOW_FROM; do
  [[ "${s,,}" == "all" ]] && { printf 'error: refusing "Allow all" (open access)\n' >&2; exit 1; }
done

[[ -f "$CUPSD_CONF" ]] || { printf 'error: %s not found\n' "$CUPSD_CONF" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.in"' EXIT

# If cupsd.conf has no ServerAlias line yet, stage one after line 1 so the
# rewrite below has something to replace.
src="$CUPSD_CONF"
if ! grep -qE '^[[:space:]]*ServerAlias([[:space:]]|$)' "$CUPSD_CONF"; then
  awk 'NR==1{print; print "ServerAlias PLACEHOLDER"; next} {print}' "$CUPSD_CONF" >"$tmp.in"
  src="$tmp.in"
fi

# Rewrite: replace the ServerAlias line, and replace the root <Location />
# Order/Allow/Deny rules with exactly what .env specifies. Comments and every
# other block (including the authenticated <Location /admin*> blocks) are kept.
awk -v alias="$CUPS_SERVER_ALIAS" -v allow="$CUPS_ALLOW_FROM" '
  BEGIN { n = split(allow, A, /[ \t]+/) }
  # CUPS reads one hostname per ServerAlias line, so emit one line per name and
  # drop every pre-existing ServerAlias line (keeps re-runs idempotent).
  /^[[:space:]]*ServerAlias([[:space:]]|$)/ {
    if (!ali) {
      m = split(alias, AL, /[ \t]+/)
      for (j = 1; j <= m; j++) if (AL[j] != "") print "ServerAlias " AL[j]
      ali = 1
    }
    next
  }
  $0 ~ /^<Location \/>[[:space:]]*$/ { inloc=1; print; next }
  inloc && /^<\/Location>/ {
    print "  Order allow,deny"
    for (i = 1; i <= n; i++) if (A[i] != "") print "  Allow " A[i]
    inloc=0; print; next
  }
  inloc && /^[[:space:]]*(Allow|Deny|Order)([[:space:]]|$)/ { next }
  { print }
' "$src" >"$tmp"

if ! cmp -s "$CUPSD_CONF" "$tmp"; then
  echo "--- pending changes to $CUPSD_CONF ---"
  diff -u "$CUPSD_CONF" "$tmp" || true
else
  echo "no changes needed — $CUPSD_CONF already matches .env"
fi

# Syntax-check the candidate before it can ever be installed.
CUPSD_BIN="$(command -v cupsd || true)"
for c in /usr/sbin/cupsd /sbin/cupsd; do [[ -z "$CUPSD_BIN" && -x "$c" ]] && CUPSD_BIN="$c"; done
if [[ -n "$CUPSD_BIN" ]]; then
  "$CUPSD_BIN" -t -c "$tmp" >/dev/null 2>&1 && echo "cupsd -t: OK" \
    || { echo "error: cupsd rejected the rendered config; aborting"; "$CUPSD_BIN" -t -c "$tmp" || true; exit 1; }
else
  echo "warning: cupsd not found; skipping syntax check"
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] not writing $CUPSD_CONF, not restarting cups.service"
  exit 0
fi

[[ $EUID -eq 0 ]] || { printf 'error: run with sudo to apply: sudo bash %s\n' "$0" >&2; exit 1; }

if cmp -s "$CUPSD_CONF" "$tmp"; then
  echo "already up to date; nothing to do"
  exit 0
fi

bk="$CUPSD_CONF.bak.$(date +%s)"
cp -a "$CUPSD_CONF" "$bk"
echo "backup: $bk"
install -o root -g root -m 640 "$tmp" "$CUPSD_CONF"
systemctl restart cups.service
echo "applied and restarted cups.service"
