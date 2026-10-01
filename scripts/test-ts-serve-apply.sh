#!/usr/bin/env bash
# Regression tests for scripts/ts-serve-apply.sh (docs/ONE_NODE_PER_HOST.md
# section 3). `tailscale` is a stub on PATH that serves canned status JSON and
# logs every call, so no test touches a real tailscaled.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$REPO_ROOT/scripts/ts-serve-apply.sh"
SERVER_TPL="$REPO_ROOT/linux-server/tailscale-serve/serve.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
unset TS_CERT_DOMAIN TS_MAGICDNS_SUFFIX

CERT=server.example.ts.net
SUFFIX=example.ts.net

FAILS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }
ok() { printf 'ok   %s\n' "$1"; }

cat > "$STUBS/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/calls"
case "$*" in
  version) cat "$STATE/version" ;;
  "status --json") cat "$STATE/status.json" ;;
  "serve status --json") cat "$STATE/serve.json" ;;
  "serve set-raw")
    if [[ -f "$STATE/drop_on_write" ]]; then jq 'del(.Web)' > "$STATE/serve.json"; else cat > "$STATE/serve.json"; fi ;;
  "serve advertise "*) ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$STUBS/tailscale"

# Fresh fake host: $1 = name, $2 = tags JSON array.
new_host() {
  export STATE="$WORK/$1"
  mkdir -p "$STATE/tpl"
  cp "$SERVER_TPL" "$STATE/tpl/serve.json"
  printf '1.102.3\n  tailscale commit: stub\n' > "$STATE/version"
  jq -n --arg dns "$CERT." --arg sfx "$SUFFIX" --argjson tags "${2:-[\"tag:server\"]}" \
    '{BackendState: "Running", Self: {DNSName: $dns, Tags: $tags}, CurrentTailnet: {MagicDNSSuffix: $sfx}}' \
    > "$STATE/status.json"
  : > "$STATE/serve.json"
  : > "$STATE/calls"
}

good_env() { printf 'TS_CERT_DOMAIN=%s\nTS_MAGICDNS_SUFFIX="%s"\n' "$CERT" "$SUFFIX" > "$STATE/tpl/.env"; }

# Runs the script; RC, OUT (stdout) and ERR (stderr) hold the result.
apply() {
  RC=0
  PATH="$STUBS:$PATH" bash "$APPLY" "$@" > "$STATE/out" 2> "$STATE/err" || RC=$?
  OUT="$(<"$STATE/out")" ERR="$(<"$STATE/err")"
}

writes() { grep -cE '^serve (set-raw|advertise)' "$STATE/calls" || true; }
only_reads() { ! grep -vqE '^(version|status --json|serve status --json)$' "$STATE/calls"; }
serve_has() { jq -e "$1" "$STATE/serve.json" >/dev/null; }

expect_err() {
  local name="$1" pattern="$2"; shift 2
  apply "$@"
  if [[ $RC != 0 ]] && grep -qE -- "$pattern" <<< "$ERR" && [[ "$(writes)" == 0 ]]; then
    ok "$name"
  else
    fail "$name: rc=$RC err=$ERR"
  fi
}

# ── Render values ────────────────────────────────────────────────────────────
new_host env
RC=0
TS_CERT_DOMAIN=$CERT TS_MAGICDNS_SUFFIX=$SUFFIX PATH="$STUBS:$PATH" \
  bash "$APPLY" "$STATE/tpl/serve.json" --dry-run > "$STATE/out" 2> "$STATE/err" || RC=$?
OUT="$(<"$STATE/out")"
[[ $RC == 0 ]] && grep -qF "\"$CERT:8443\"" <<< "$OUT" && grep -qF "\"forgejo.$SUFFIX:443\"" <<< "$OUT" \
  && ! grep -qF '${' <<< "$OUT" && ! grep -q warning "$STATE/err" \
  && ok 'renders both placeholders from the environment' || fail "env render: rc=$RC $(<"$STATE/err")"

new_host precedence
printf 'TS_CERT_DOMAIN=other.%s\nTS_MAGICDNS_SUFFIX=%s\n' "$SUFFIX" "$SUFFIX" > "$STATE/tpl/.env"
RC=0
TS_CERT_DOMAIN=$CERT PATH="$STUBS:$PATH" bash "$APPLY" "$STATE/tpl/serve.json" --dry-run \
  > "$STATE/out" 2> "$STATE/err" || RC=$?
[[ $RC == 0 ]] && ok 'environment wins over .env' || fail "precedence env>.env: $(<"$STATE/err")"
apply "$STATE/tpl/serve.json" --dry-run
[[ $RC != 0 ]] && grep -q 'TS_CERT_DOMAIN from .*\.env does not match the live node' <<< "$ERR" \
  && ! grep -qF "other.$SUFFIX" <<< "$ERR" \
  && ok 'drift: .env differs from the live node, value not printed' || fail "drift: $ERR"

new_host dotenv
good_env
apply "$STATE/tpl/serve.json" --dry-run
[[ $RC == 0 && -z "$ERR" ]] && grep -qF "\"$CERT:443\"" <<< "$OUT" \
  && ok '.env values (quoted and bare) render' || fail ".env render: $ERR"

new_host fallback
apply "$STATE/tpl/serve.json" --dry-run
[[ $RC == 0 ]] && grep -q 'warning: .*/\.env not found; using values from tailscale status' <<< "$ERR" \
  && ok 'missing .env falls back to tailscale status with a warning' || fail "fallback: $ERR"

new_host malformed
printf '# comment\n\nTS_CERT_DOMAIN=%s\nexport TS_MAGICDNS_SUFFIX=%s\n' "$CERT" "$SUFFIX" > "$STATE/tpl/.env"
expect_err 'malformed .env line' '\.env:4: not a KEY=value line' "$STATE/tpl/serve.json" --dry-run

new_host unknown
good_env; printf 'TS_HOSTNAME=x\n' >> "$STATE/tpl/.env"
expect_err 'unknown .env key' '\.env:3: unknown key TS_HOSTNAME' "$STATE/tpl/serve.json" --dry-run

new_host empty
printf 'TS_CERT_DOMAIN=%s\nTS_MAGICDNS_SUFFIX=\n' "$CERT" > "$STATE/tpl/.env"
expect_err 'empty .env key does not fall back' 'TS_MAGICDNS_SUFFIX is missing or empty' "$STATE/tpl/serve.json" --dry-run

new_host placeholder
cp "$REPO_ROOT/linux-server/tailscale-serve/.env.example" "$STATE/tpl/.env"
expect_err 'unedited .env.example copy' 'TS_MAGICDNS_SUFFIX from .* is not a lower-case' "$STATE/tpl/serve.json" --dry-run

new_host uppercase
printf 'TS_CERT_DOMAIN=Server.%s\nTS_MAGICDNS_SUFFIX=%s\n' "$SUFFIX" "$SUFFIX" > "$STATE/tpl/.env"
expect_err 'TS_CERT_DOMAIN format' 'TS_CERT_DOMAIN from .* is not one <host> label' "$STATE/tpl/serve.json" --dry-run

# ── Preconditions ────────────────────────────────────────────────────────────
new_host oldver
good_env; printf '1.100.0\n' > "$STATE/version"
expect_err 'tailscale below the version floor' 'older than 1.102.3' "$STATE/tpl/serve.json" --dry-run

new_host stopped
good_env; jq '.BackendState = "Stopped"' "$STATE/status.json" > "$STATE/s" && mv "$STATE/s" "$STATE/status.json"
expect_err 'BackendState not Running' 'BackendState is not Running' "$STATE/tpl/serve.json" --dry-run

new_host untagged '[]'
good_env
expect_err 'Services need a tagged host' 'Services need a tagged host' "$STATE/tpl/serve.json" --dry-run
apply "$STATE/tpl/serve.json" --services none --dry-run
[[ $RC == 0 ]] && ok '--services none runs on an untagged host' || fail "untagged none: $ERR"

# ── Validation ───────────────────────────────────────────────────────────────
# $1 = name, $2 = expected error, $3 = jq edit of the template.
bad_tpl() {
  new_host "bad-$1"
  good_env
  jq "$3" "$SERVER_TPL" > "$STATE/tpl/serve.json"
  expect_err "validation: $1" "$2" "$STATE/tpl/serve.json" --dry-run
}
bad_tpl toplevel 'top-level keys not allowed: AllowFunnel' '.AllowFunnel = {}'
bad_tpl nohttps 'Web :8443 has no TCP 8443 with HTTPS: true' 'del(.TCP["8443"])'
bad_tpl remote 'handler :443/glances/ Proxy must be' '.Web["${TS_CERT_DOMAIN}:443"].Handlers["/glances/"].Proxy = "http://192.0.2.1:61208"'
bad_tpl localhost 'Proxy must be' '.Web["${TS_CERT_DOMAIN}:443"].Handlers["/"].Proxy = "http://localhost:3000"'
bad_tpl pathhandler 'uses Path; only Proxy' '.Web["${TS_CERT_DOMAIN}:443"].Handlers["/files/"] = {Path: "/srv"}'
bad_tpl textproxy 'uses Text; only Proxy' '.Web["${TS_CERT_DOMAIN}:443"].Handlers["/"].Text = "hi"'
bad_tpl tcpforward 'svc:forgejo: TCP 22 TCPForward must be 127.0.0.1' '.Services["svc:forgejo"].TCP["22"].TCPForward = "0.0.0.0:2222"'
bad_tpl svcname 'svc:ntfy: Web key :443 is not ntfy' '.Services["svc:ntfy"].Web = {"forgejo.${TS_MAGICDNS_SUFFIX}:443": .Services["svc:ntfy"].Web[]}'
bad_tpl port5252 'port 5252 is reserved' '.TCP["5252"] = {HTTPS: true}'
bad_tpl svcnohttps 'svc:immich: Web :443 has no TCP 443' 'del(.Services["svc:immich"].TCP["443"])'
bad_tpl placeholder 'placeholder is left after rendering' '.Web["${TS_CERT_DOMAIN}:443"].Handlers["/"].Proxy = "http://127.0.0.1:${PORT}"'

new_host badjson
good_env
printf '{ "TCP": {' > "$STATE/tpl/serve.json"
expect_err 'validation: invalid JSON' 'not valid JSON after rendering' "$STATE/tpl/serve.json" --dry-run

# ── Dry run ──────────────────────────────────────────────────────────────────
new_host dry
good_env
apply "$STATE/tpl/serve.json" --dry-run
[[ $RC == 0 && "$(writes)" == 0 ]] && only_reads && [[ ! -s "$STATE/serve.json" ]] \
  && grep -q '^==> Diff' <<< "$OUT" && grep -q 'tailscale serve set-raw' <<< "$OUT" \
  && grep -q 'tailscale serve advertise svc:forgejo' <<< "$OUT" \
  && ok '--dry-run prints the plan and calls only read-only commands' || fail "dry-run: rc=$RC $(<"$STATE/calls")"

# ── Apply, merge and re-apply ────────────────────────────────────────────────
new_host merge
good_env
jq -n --arg h "$CERT" '{
  TCP: {"443": {HTTPS: true}, "9999": {TCPForward: "127.0.0.1:9999"}},
  Web: {
    ("\($h):443"): {Handlers: {"/": {Proxy: "http://127.0.0.1:3000"}, "/byhand/": {Proxy: "http://127.0.0.1:7000"}}},
    "other.example.ts.net:443": {Handlers: {"/": {Proxy: "http://127.0.0.1:7001"}}}
  },
  Services: {"svc:other": {TCP: {"443": {HTTPS: true}}}},
  AllowFunnel: {"x:443": false}
}' > "$STATE/serve.json"
apply "$STATE/tpl/serve.json" --services none
[[ $RC == 0 ]] || fail "merge apply: $ERR"
serve_has '.TCP["9999"].TCPForward == "127.0.0.1:9999" and .Web["other.example.ts.net:443"] and .Services["svc:other"] and .AllowFunnel' \
  && ok 'merge keeps unrelated ports, Web hosts, Services and AllowFunnel' || fail 'merge dropped an unrelated key'
serve_has ".Web[\"$CERT:443\"].Handlers | has(\"/glances/\") and (has(\"/byhand/\") | not)" \
  && ok 'the template owns the whole :443 listener (hand mount removed)' || fail 'hand-added mount survived'
serve_has '(.Services | keys) == ["svc:other"]' \
  && ok '--services none leaves Services alone' || fail '--services none touched Services'
[[ "$(grep -c '^serve advertise' "$STATE/calls" || true)" == 0 ]] || fail '--services none advertised a Service'

: > "$STATE/calls"
apply "$STATE/tpl/serve.json" --services svc:ntfy
[[ $RC == 0 ]] && serve_has '(.Services | keys) == ["svc:ntfy", "svc:other"]' \
  && grep -qx 'serve advertise svc:ntfy' "$STATE/calls" \
  && ok '--services svc:ntfy adds and advertises only that Service' || fail "--services svc:ntfy: $ERR"

: > "$STATE/calls"
apply "$STATE/tpl/serve.json" --services svc:ntfy
[[ $RC == 0 && "$OUT" == "up to date" && "$(writes)" == 0 ]] \
  && ok 're-apply of the same config is a no-op' || fail "no-op re-apply: rc=$RC out=$OUT"

expect_err '--services with a name not in the template' 'svc:nope is not in' "$STATE/tpl/serve.json" --services svc:nope

apply "$STATE/tpl/serve.json"
[[ $RC == 0 ]] && serve_has '(.Services | keys) == ["svc:forgejo", "svc:immich", "svc:ntfy", "svc:other"]' \
  && serve_has '.Services["svc:forgejo"].TCP["22"].TCPForward == "127.0.0.1:2222"' \
  && ok 'default --services all applies every template Service' || fail "services all: $ERR"

# ── Conflicts and read-back ──────────────────────────────────────────────────
new_host conflict
good_env
jq -n '{TCP: {"8444": {HTTP: true}}}' > "$STATE/serve.json"
expect_err 'conflicting listener type stops the run' 'node port 8444 is HTTP, the template wants HTTPS' "$STATE/tpl/serve.json" --services none

new_host svcconflict
good_env
jq -n '{Services: {"svc:forgejo": {TCP: {"22": {HTTPS: true}}}}}' > "$STATE/serve.json"
expect_err 'conflicting Service listener stops the run' 'svc:forgejo port 22 is HTTPS, the template wants TCPForward' "$STATE/tpl/serve.json"

new_host nullserve
good_env
printf 'null\n' > "$STATE/serve.json"
apply "$STATE/tpl/serve.json" --services none
[[ $RC == 0 ]] && serve_has '.TCP["443"].HTTPS' && ok 'null serve status is treated as {}' || fail "null serve: $ERR"

new_host readback
good_env
touch "$STATE/drop_on_write"
apply "$STATE/tpl/serve.json" --services none
[[ $RC != 0 ]] && grep -q 'read-back' <<< "$ERR" \
  && ok 'read-back mismatch exits non-zero' || fail "read-back: rc=$RC $ERR"

if (( FAILS > 0 )); then
  printf 'ts-serve-apply tests: %d FAILED\n' "$FAILS" >&2
  exit 1
fi
printf 'ts-serve-apply tests passed.\n'
