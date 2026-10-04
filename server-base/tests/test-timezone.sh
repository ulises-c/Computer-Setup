#!/usr/bin/env bash
set -euo pipefail

# Tests for server-base/timezone.sh with stubbed timedatectl and docker on PATH
# and a fake zoneinfo tree.

SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/timezone.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/zoneinfo/America" "$tmp/zoneinfo/Europe"
touch "$tmp/zoneinfo/America/Los_Angeles" "$tmp/zoneinfo/Europe/Berlin"

cat >"$tmp/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_TZ:-}" ]] && printf '%s\n' "$STUB_TZ"
exit 0
EOF

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DOCKER_LOG"
case "$1" in
  ps) printf 'aaa\nbbb\nccc\nddd\n' ;;
  inspect)
    cat <<'JSON'
[
  {"Name": "/uptime-kuma", "Config": {"Env": ["PATH=/bin", "TZ=America/Los_Angeles"], "Labels": {
    "com.docker.compose.project": "uptime-kuma",
    "com.docker.compose.project.working_dir": "/srv/uptime-kuma",
    "com.docker.compose.project.config_files": "/srv/uptime-kuma/docker-compose.yml,/srv/uptime-kuma/override.yml",
    "com.docker.compose.service": "uptime-kuma"}}},
  {"Name": "/glances", "Config": {"Env": ["TZ=Europe/Berlin"], "Labels": {
    "com.docker.compose.project": "glances",
    "com.docker.compose.project.working_dir": "/srv/glances",
    "com.docker.compose.project.config_files": "/srv/glances/docker-compose.yml",
    "com.docker.compose.service": "glances"}}},
  {"Name": "/uptime-kuma-ts", "Config": {"Env": ["TS_STATE_DIR=/var/lib/tailscale"], "Labels": {
    "com.docker.compose.project": "uptime-kuma",
    "com.docker.compose.project.working_dir": "/srv/uptime-kuma",
    "com.docker.compose.project.config_files": "/srv/uptime-kuma/docker-compose.yml",
    "com.docker.compose.service": "uptime-kuma-ts"}}},
  {"Name": "/manual", "Config": {"Env": ["TZ=UTC"], "Labels": null}}
]
JSON
    ;;
esac
EOF
chmod +x "$tmp/bin/timedatectl" "$tmp/bin/docker"

export PATH="$tmp/bin:$PATH" ZONEINFO_DIR="$tmp/zoneinfo" TIMEZONE_ENV="$tmp/timezone.env"
export LOCALTIME_PATH="$tmp/localtime" STUB_DOCKER_LOG="$tmp/docker.log"

# --- timedatectl is the primary source ---------------------------------------
STUB_TZ=Europe/Berlin bash "$SCRIPT" >/dev/null
[[ "$(<"$TIMEZONE_ENV")" == "TZ=Europe/Berlin" ]] || fail "timedatectl zone not written"
[[ "$(wc -l <"$TIMEZONE_ENV")" -eq 1 ]] || fail "timezone.env is not exactly one line"

# --- unchanged content is not rewritten ---------------------------------------
touch -t 200001010000 "$TIMEZONE_ENV"
touch -t 200101010000 "$tmp/marker"
out="$(STUB_TZ=Europe/Berlin bash "$SCRIPT")"
[[ "$out" == unchanged:* ]] || fail "rerun did not report unchanged: $out"
[[ "$TIMEZONE_ENV" -nt "$tmp/marker" ]] && fail "unchanged file was rewritten"

# --- falls back to the /etc/localtime symlink ---------------------------------
ln -s "../usr/share/zoneinfo/America/Los_Angeles" "$LOCALTIME_PATH"
bash "$SCRIPT" >/dev/null
[[ "$(<"$TIMEZONE_ENV")" == "TZ=America/Los_Angeles" ]] || fail "localtime fallback not written"

# --- invalid or unknown names are rejected, file untouched --------------------
for bad in '../../etc/passwd' 'Mars/Olympus_Mons' 'America/Los Angeles' '/America/Los_Angeles'; do
  if STUB_TZ="$bad" bash "$SCRIPT" >/dev/null 2>&1; then
    fail "accepted invalid zone: $bad"
  fi
done
[[ "$(<"$TIMEZONE_ENV")" == "TZ=America/Los_Angeles" ]] || fail "rejected zone changed the file"
rm "$LOCALTIME_PATH"
if bash "$SCRIPT" >/dev/null 2>&1; then
  fail "succeeded with no zone source"
fi

# --- --dry-run writes nothing --------------------------------------------------
out="$(STUB_TZ=Europe/Berlin bash "$SCRIPT" --dry-run)"
[[ "$out" == "[dry-run] write $TIMEZONE_ENV: TZ=Europe/Berlin" ]] || fail "dry-run output: $out"
[[ "$(<"$TIMEZONE_ENV")" == "TZ=America/Los_Angeles" ]] || fail "dry-run wrote the file"

# --- --apply --dry-run: only stale compose services, grouped per project -----
: >"$STUB_DOCKER_LOG"
out="$(STUB_TZ=Europe/Berlin bash "$SCRIPT" --apply --dry-run)"
expected='[dry-run] docker compose -p uptime-kuma --project-directory /srv/uptime-kuma -f /srv/uptime-kuma/docker-compose.yml -f /srv/uptime-kuma/override.yml up -d --no-deps uptime-kuma'
grep -qxF -- "$expected" <<<"$out" || fail "missing compose up for stale service: $out"
[[ "$(grep -c '^\[dry-run\] docker compose' <<<"$out")" -eq 1 ]] || fail "recreated more than the stale service: $out"
grep -q '^skip manual:' <<<"$out" || fail "non-compose container not reported: $out"
grep -q '1 service(s) recreated in 1 project(s), 1 container(s) already on Europe/Berlin, 1 skipped' <<<"$out" \
  || fail "summary: $out"
grep -q '^compose' "$STUB_DOCKER_LOG" && fail "dry-run ran docker compose"

# --- --apply runs the compose command ----------------------------------------
: >"$STUB_DOCKER_LOG"
STUB_TZ=Europe/Berlin bash "$SCRIPT" --apply >/dev/null
[[ "$(<"$TIMEZONE_ENV")" == "TZ=Europe/Berlin" ]] || fail "--apply did not write the zone"
grep -qxF 'compose -p uptime-kuma --project-directory /srv/uptime-kuma -f /srv/uptime-kuma/docker-compose.yml -f /srv/uptime-kuma/override.yml up -d --no-deps uptime-kuma' \
  "$STUB_DOCKER_LOG" || fail "--apply did not recreate the stale service: $(<"$STUB_DOCKER_LOG")"

# --- --apply without docker fails --------------------------------------------
mkdir "$tmp/nodocker"
for tool in bash dirname readlink mktemp chmod mv; do
  ln -s "$(command -v "$tool")" "$tmp/nodocker/$tool"
done
ln -s "$tmp/bin/timedatectl" "$tmp/nodocker/timedatectl"
if out="$(STUB_TZ=Europe/Berlin PATH="$tmp/nodocker" bash "$SCRIPT" --apply 2>&1)"; then
  fail "--apply succeeded without docker"
fi
grep -q 'docker not found' <<<"$out" || fail "missing-docker message: $out"

printf 'test-timezone: PASSED\n'
