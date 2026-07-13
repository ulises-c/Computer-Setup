#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local value="$1"
  local expected="$2"

  [[ "$value" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_not_contains() {
  local value="$1"
  local unexpected="$2"

  [[ "$value" != *"$unexpected"* ]] || fail "output exposed a protected test value"
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local path="$3"
  local actual

  actual="$(grep -Ec "$pattern" "$path" || true)"
  [[ "$actual" == "$expected" ]] || fail "expected $expected matches for $pattern, found $actual"
}

write_env() {
  local aliases="$1"
  local sidecar="$2"
  local lan="$3"

  printf 'CUPS_SERVER_ALIAS="%s"\nCUPS_SIDECAR_SUBNET="%s"\nCUPS_LAN_SUBNET="%s"\n' \
    "$aliases" "$sidecar" "$lan" > "$work/.env"
  chmod 600 "$work/.env"
}

write_fixture() {
  local path="$1"

  printf '%s\n' \
    'LogLevel warn' \
    'Listen localhost:631' \
    'Listen /run/cups/cups.sock' \
    'Port 8631' \
    'ServerAlias *' \
    '<Location />' \
    '  Order deny,allow' \
    '  Allow all' \
    '</Location>' \
    '<Location /admin>' \
    '  Allow all' \
    '</Location>' \
    '<Location /admin/conf>' \
    '  AuthType Default' \
    '  Require user @SYSTEM' \
    '  Order deny,allow' \
    '  Allow all' \
    '</Location>' \
    '<Location /admin/log>' \
    '  AuthType Default' \
    '  Require user @SYSTEM' \
    '  Allow all' \
    '</Location>' \
    'Browsing On' > "$path"
}

write_stub() {
  local name="$1"
  shift

  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$@" > "$stubs/$name"
  chmod +x "$stubs/$name"
}

run_setup() {
  PATH="$stubs:$PATH" \
    CUPSD_BIN="$stubs/cupsd" \
    CUPSD_CONF="$config" \
    CUPS_REVIEW_DIR="$review" \
    SYSTEMCTL_LOG="$systemctl_log" \
    bash "$work/setup.sh" "$@"
}

run_invalid() {
  local description="$1"
  local output

  if output="$(run_setup --dry-run 2>&1)"; then
    fail "invalid input accepted: $description"
  fi
  assert_not_contains "$output" 'printer.family.lan'
  assert_not_contains "$output" '192.168.50.0/24'
}

cp "$SCRIPT_DIR/setup.sh" "$work/setup.sh"
chmod +x "$work/setup.sh"
stubs="$work/stubs"
mkdir -p "$stubs"
systemctl_log="$work/systemctl.log"

write_stub cupsd '[[ "${CUPSD_FAIL:-false}" != true ]]'
write_stub curl '[[ "${CURL_FAIL:-false}" != true ]]'
write_stub systemctl 'printf "%s\n" "$*" >> "$SYSTEMCTL_LOG"' 'exit 0'
write_stub id 'if [[ "${1:-}" == "-u" ]]; then printf "0\n"; else /usr/bin/id "$@"; fi'
write_stub stat \
  'path=""' \
  'for argument in "$@"; do path="$argument"; done' \
  'if [[ "${1:-}" == "-c" && "${2:-}" == "%u" ]]; then printf "0\n"' \
  'elif [[ "${1:-}" == "-c" && "${2:-}" == "%a" ]]; then if [[ -d "$path" ]]; then printf "700\n"; else printf "600\n"; fi' \
  'else /usr/bin/stat "$@"; fi'
write_stub install \
  'directory=false' \
  'mode=""' \
  'args=()' \
  'while (( $# > 0 )); do' \
  '  case "$1" in' \
  '    -d) directory=true; shift ;;' \
  '    -m) mode="$2"; shift 2 ;;' \
  '    -o|-g) shift 2 ;;' \
  '    *) args+=("$1"); shift ;;' \
  '  esac' \
  'done' \
  'if [[ "$directory" == true ]]; then mkdir -p "${args[0]}"; target="${args[0]}"' \
  'else cp "${args[0]}" "${args[1]}"; target="${args[1]}"' \
  'fi' \
  '[[ -z "$mode" ]] || chmod "$mode" "$target"'

config="$work/cupsd.conf"
review="$work/review"
write_fixture "$config"
write_env 'printer.family.lan printer printer.local' '172.21.0.0/16' '192.168.50.0/24'

output="$(run_setup --dry-run 2>&1)"
assert_contains "$output" 'validation passed; policy changes are pending'
for protected_value in printer.family.lan printer.local 172.21.0.0/16 192.168.50.0/24; do
  assert_not_contains "$output" "$protected_value"
done

output="$(run_setup --prepare-review 2>&1)"
assert_contains "$output" 'review artifacts prepared with root-only permissions'
for protected_value in printer.family.lan printer.local 172.21.0.0/16 192.168.50.0/24; do
  assert_not_contains "$output" "$protected_value"
done

candidate="$review/candidate.conf"
[[ -f "$candidate" ]] || fail 'candidate was not prepared'
assert_count 1 '^[[:space:]]*Port[[:space:]]+631[[:space:]]*$' "$candidate"
assert_count 0 '^[[:space:]]*Port[[:space:]]+8631[[:space:]]*$' "$candidate"
assert_count 0 '^[[:space:]]*Listen[[:space:]]+localhost:631[[:space:]]*$' "$candidate"
assert_count 1 '^[[:space:]]*Listen[[:space:]]+/run/cups/cups.sock[[:space:]]*$' "$candidate"
assert_count 3 '^[[:space:]]*ServerAlias[[:space:]]+' "$candidate"
assert_count 0 '^[[:space:]]*Allow[[:space:]]+all[[:space:]]*$' "$candidate"
assert_count 3 '^[[:space:]]*Require[[:space:]]+user[[:space:]]+@SYSTEM[[:space:]]*$' "$candidate"

print_block="$(awk '/^<Location \/>$/, /^<\/Location>$/' "$candidate")"
admin_block="$(awk '/^<Location \/admin>$/, /^<\/Location>$/' "$candidate")"
admin_conf_block="$(awk '/^<Location \/admin\/conf>$/, /^<\/Location>$/' "$candidate")"
admin_log_block="$(awk '/^<Location \/admin\/log>$/, /^<\/Location>$/' "$candidate")"
assert_count 3 '^[[:space:]]*Allow[[:space:]]+' <(printf '%s\n' "$print_block")
assert_count 2 '^[[:space:]]*Allow[[:space:]]+' <(printf '%s\n' "$admin_block")
assert_count 2 '^[[:space:]]*Allow[[:space:]]+' <(printf '%s\n' "$admin_conf_block")
assert_count 2 '^[[:space:]]*Allow[[:space:]]+' <(printf '%s\n' "$admin_log_block")
assert_contains "$print_block" 'Allow 192.168.50.0/24'
assert_contains "$admin_block" 'AuthType Default'
assert_contains "$admin_block" 'Require user @SYSTEM'
assert_not_contains "$admin_block" '192.168.50.0/24'
assert_contains "$admin_conf_block" 'AuthType Default'
assert_contains "$admin_conf_block" 'Require user @SYSTEM'
assert_not_contains "$admin_conf_block" '192.168.50.0/24'
assert_contains "$admin_log_block" 'AuthType Default'
assert_contains "$admin_log_block" 'Require user @SYSTEM'
assert_not_contains "$admin_log_block" '192.168.50.0/24'

expected="$work/expected.conf"
cp "$candidate" "$expected"
source_hash="$(awk '$1 == "source" { print $2 }' "$review/manifest")"
candidate_hash="$(awk '$1 == "candidate" { print $2 }' "$review/manifest")"
output="$(run_setup --apply-reviewed "$source_hash" "$candidate_hash" 2>&1)"
assert_contains "$output" 'reviewed policy applied'
cmp -s "$config" "$expected" || fail 'apply did not install the reviewed candidate'
assert_contains "$(<"$systemctl_log")" 'disable --now cups.socket'
assert_contains "$(<"$systemctl_log")" 'enable cups.service'
assert_contains "$(<"$systemctl_log")" 'restart cups.service'
for protected_value in printer.family.lan printer.local 172.21.0.0/16 192.168.50.0/24; do
  assert_not_contains "$output" "$protected_value"
done

output="$(run_setup --dry-run 2>&1)"
assert_contains "$output" 'validation passed; no policy changes are pending'
run_setup --prepare-review >/dev/null
cmp -s "$config" "$review/candidate.conf" || fail 'renderer is not idempotent'

config="$work/cupsd-rollback.conf"
review="$work/review-rollback"
write_fixture "$config"
cp "$config" "$work/rollback-original.conf"
run_setup --prepare-review >/dev/null
source_hash="$(awk '$1 == "source" { print $2 }' "$review/manifest")"
candidate_hash="$(awk '$1 == "candidate" { print $2 }' "$review/manifest")"
if output="$(CURL_FAIL=true run_setup --apply-reviewed "$source_hash" "$candidate_hash" 2>&1)"; then
  fail 'failed local probe did not abort apply'
fi
assert_contains "$output" 'restoring the previous CUPS configuration'
cmp -s "$config" "$work/rollback-original.conf" || fail 'rollback did not restore the original configuration'

config="$work/cupsd-invalid.conf"
review="$work/review-invalid"
write_fixture "$config"

printf '%s\n' \
  '<Location /printers>' \
  '  Allow from all' \
  '</Location>' >> "$config"
write_env 'printer.family.lan printer printer.local' '172.21.0.0/16' '192.168.50.0/24'
run_invalid 'open access in an unmanaged specific Location'

write_fixture "$config"

write_env 'printer.family.lan printer printer.local' '172.21.0.0/16' '0.0.0.0/0'
run_invalid 'open LAN network'

write_env 'printer.family.lan printer printer.local' '172.21.0.0/16' '192.168.50.7/24'
run_invalid 'non-canonical LAN network'

write_env 'printer.family.lan printer printer.local' '172.22.0.0/16' '192.168.50.0/24'
run_invalid 'sidecar network that differs from the Compose pin'

write_env 'printer.family.lan printer printer.local' '172.21.0.0/16' '172.21.4.0/24'
run_invalid 'LAN network that overlaps the sidecar network'

write_env 'Printer.family.lan printer printer.local' '172.21.0.0/16' '192.168.50.0/24'
run_invalid 'non-canonical hostname'

write_env $'printer.family.lan\nAllow all' '172.21.0.0/16' '192.168.50.0/24'
run_invalid 'hostname newline injection'

printf 'PASS: CUPS policy renderer, privacy, review/apply, rollback, idempotency, and validation\n'
