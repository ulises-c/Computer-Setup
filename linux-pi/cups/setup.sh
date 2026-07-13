#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CUPSD_CONF="${CUPSD_CONF:-/etc/cups/cupsd.conf}"
CUPS_REVIEW_DIR="${CUPS_REVIEW_DIR:-/var/lib/cups-policy-review}"
PINNED_SIDECAR_SUBNET="172.21.0.0/16"

usage() {
  printf 'usage: bash setup.sh --dry-run | --prepare-review | --apply-reviewed <source-sha256> <candidate-sha256>\n' >&2
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    fail 'sha256sum or shasum is required'
  fi
}

stat_uid() {
  local path="$1"

  stat -c '%u' "$path" 2>/dev/null || stat -f '%u' "$path"
}

stat_mode() {
  local path="$1"

  stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path"
}

require_root() {
  [[ "$(id -u)" == 0 ]] || fail 'run this operation with sudo'
}

validate_hostname() {
  local hostname="$1"
  local label
  local -a labels

  [[ ${#hostname} -le 253 ]] || return 1
  [[ "$hostname" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$hostname" != .* && "$hostname" != *. && "$hostname" != *..* ]] || return 1

  IFS='.' read -r -a labels <<< "$hostname"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_private_cidr() {
  local cidr="$1"
  local ip prefix octet first second ip_int mask
  local -a octets

  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$prefix" == "$((10#$prefix))" ]] || return 1
  (( prefix >= 16 && prefix <= 30 )) || return 1

  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
    [[ "$octet" == "$((10#$octet))" ]] || return 1
  done

  first=$((10#${octets[0]}))
  second=$((10#${octets[1]}))
  if ! (( first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168) )); then
    return 1
  fi

  ip_int=$(( (first << 24) | (second << 16) | (10#${octets[2]} << 8) | 10#${octets[3]} ))
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (ip_int & mask) == ip_int ))
}

load_policy() {
  local env_file="$SCRIPT_DIR/.env"
  local alias_name seen=""
  local -a aliases

  [[ -f "$env_file" && ! -L "$env_file" ]] || fail 'create a regular .env from .env.example first'
  [[ "$(stat_mode "$env_file")" == 600 ]] || fail 'set .env permissions to 0600 before use'
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  : "${CUPS_SERVER_ALIAS:?set CUPS_SERVER_ALIAS in .env}"
  : "${CUPS_LAN_SUBNET:?set CUPS_LAN_SUBNET in .env}"
  CUPS_SIDECAR_SUBNET="${CUPS_SIDECAR_SUBNET:-$PINNED_SIDECAR_SUBNET}"

  [[ "$CUPS_SERVER_ALIAS" =~ ^[a-z0-9.-]+(\ [a-z0-9.-]+)*$ ]] \
    || fail 'CUPS_SERVER_ALIAS must contain only canonical lowercase hostnames separated by single spaces'
  read -r -a aliases <<< "$CUPS_SERVER_ALIAS"
  (( ${#aliases[@]} > 0 )) || fail 'CUPS_SERVER_ALIAS must not be empty'

  for alias_name in "${aliases[@]}"; do
    validate_hostname "$alias_name" || fail 'CUPS_SERVER_ALIAS contains an invalid hostname'
    [[ " $seen " != *" $alias_name "* ]] || fail 'CUPS_SERVER_ALIAS contains a duplicate hostname'
    seen+="${seen:+ }$alias_name"
  done

  validate_private_cidr "$CUPS_SIDECAR_SUBNET" || fail 'CUPS_SIDECAR_SUBNET must be a canonical private IPv4 CIDR'
  [[ "$CUPS_SIDECAR_SUBNET" == "$PINNED_SIDECAR_SUBNET" ]] \
    || fail 'CUPS_SIDECAR_SUBNET must match the Compose network pin'
  validate_private_cidr "$CUPS_LAN_SUBNET" || fail 'CUPS_LAN_SUBNET must be a canonical private IPv4 CIDR between /16 and /30'
  [[ ! "$CUPS_LAN_SUBNET" =~ ^172\.21\. ]] \
    || fail 'CUPS_LAN_SUBNET must not overlap the sidecar subnet'

  CUPS_PRINT_ALLOW_FROM="localhost $CUPS_SIDECAR_SUBNET $CUPS_LAN_SUBNET"
  CUPS_ADMIN_ALLOW_FROM="localhost $CUPS_SIDECAR_SUBNET"
}

location_count() {
  local path="$1"
  local target="$2"

  awk -v target="$target" '
    $0 ~ "^[[:space:]]*<Location[[:space:]]+" target ">[[:space:]]*$" { count++ }
    END { print count + 0 }
  ' "$path"
}

validate_source_shape() {
  local path="$1"

  [[ "$(location_count "$path" '\\/')" == 1 ]] \
    || fail 'cupsd.conf must contain exactly one root Location block'
  [[ "$(location_count "$path" '\\/admin')" == 1 ]] \
    || fail 'cupsd.conf must contain exactly one admin Location block'
  [[ "$(location_count "$path" '\\/admin\\/conf')" == 1 ]] \
    || fail 'cupsd.conf must contain exactly one admin/conf Location block'
}

render_candidate() {
  local source="$1"
  local destination="$2"

  validate_source_shape "$source"
  awk \
    -v aliases="$CUPS_SERVER_ALIAS" \
    -v print_allow="$CUPS_PRINT_ALLOW_FROM" \
    -v admin_allow="$CUPS_ADMIN_ALLOW_FROM" '
    function emit_aliases(  count, values, idx) {
      count = split(aliases, values, /[ ]+/)
      for (idx = 1; idx <= count; idx++) print "ServerAlias " values[idx]
    }
    function emit_access(values,  count, sources, idx) {
      print "  Order allow,deny"
      count = split(values, sources, /[ ]+/)
      for (idx = 1; idx <= count; idx++) print "  Allow " sources[idx]
    }
    function emit_admin_policy() {
      print "  AuthType Default"
      print "  Require user @SYSTEM"
      emit_access(admin_allow)
    }
    NR == 1 {
      if (!network_seen) {
        print "Port 631"
        network_seen = 1
      }
      if (!alias_seen) {
        emit_aliases()
        alias_seen = 1
      }
    }
    /^[[:space:]]*ServerAlias([[:space:]]|$)/ {
      if (!alias_replaced) {
        if (!alias_seen) emit_aliases()
        alias_replaced = 1
      }
      next
    }
    /^[[:space:]]*Port([[:space:]]|$)/ {
      if (!port_replaced) {
        if (!network_seen) print "Port 631"
        port_replaced = 1
      }
      next
    }
    /^[[:space:]]*Listen[[:space:]]+\// { print; next }
    /^[[:space:]]*Listen([[:space:]]|$)/ {
      if (!port_replaced) {
        if (!network_seen) print "Port 631"
        port_replaced = 1
      }
      next
    }
    /^[[:space:]]*<Location[[:space:]]+\/>[[:space:]]*$/ {
      block = "print"
      print
      next
    }
    /^[[:space:]]*<Location[[:space:]]+\/admin(\/[^>[:space:]]+)?>[[:space:]]*$/ {
      block = "admin"
      print
      next
    }
    block != "" && /^[[:space:]]*<\/Location>[[:space:]]*$/ {
      if (block == "print") emit_access(print_allow)
      else emit_admin_policy()
      block = ""
      print
      next
    }
    block == "admin" && /^[[:space:]]*(AuthType|Require)([[:space:]]|$)/ { next }
    block != "" && /^[[:space:]]*(Allow|Deny|Order)([[:space:]]|$)/ { next }
    { print }
  ' "$source" > "$destination"
}

validate_rendered_policy() {
  local path="$1"
  local network_count

  network_count="$(awk '
    /^[[:space:]]*Port([[:space:]]|$)/ { count++ }
    /^[[:space:]]*Listen([[:space:]]|$)/ && $0 !~ /^[[:space:]]*Listen[[:space:]]+\// { count++ }
    END { print count + 0 }
  ' "$path")"
  [[ "$network_count" == 1 ]] || fail 'rendered policy must contain exactly one TCP listener'
  [[ "$(grep -Ec '^[[:space:]]*Port[[:space:]]+631[[:space:]]*$' "$path" || true)" == 1 ]] \
    || fail 'rendered policy must contain exactly one Port 631 directive'
  ! grep -Eqi '^[[:space:]]*ServerAlias[[:space:]]+\*([[:space:]]|$)' "$path" \
    || fail 'rendered policy contains a wildcard ServerAlias'
  ! grep -Eqi '^[[:space:]]*Allow[[:space:]]+(from[[:space:]]+)?(all|0\.0\.0\.0/0|::/0)([[:space:]]|$)' "$path" \
    || fail 'rendered policy contains an open access rule'
  awk '
    /^[[:space:]]*<Location[[:space:]]+\/admin(\/[^>[:space:]]+)?>[[:space:]]*$/ {
      admin = 1
      auth = 0
      require_system = 0
      next
    }
    admin && /^[[:space:]]*AuthType[[:space:]]+Default[[:space:]]*$/ { auth++ }
    admin && /^[[:space:]]*Require[[:space:]]+user[[:space:]]+@SYSTEM[[:space:]]*$/ { require_system++ }
    admin && /^[[:space:]]*<\/Location>[[:space:]]*$/ {
      if (auth != 1 || require_system != 1) invalid = 1
      admin = 0
    }
    END { exit invalid }
  ' "$path" || fail 'every admin Location must require the system user policy'
}

find_cupsd() {
  local candidate

  if [[ -n "${CUPSD_BIN:-}" ]]; then
    [[ -x "$CUPSD_BIN" ]] || fail 'configured cupsd binary is not executable'
    return
  fi

  CUPSD_BIN="$(command -v cupsd || true)"
  for candidate in /usr/sbin/cupsd /sbin/cupsd; do
    [[ -z "$CUPSD_BIN" && -x "$candidate" ]] && CUPSD_BIN="$candidate"
  done
  [[ -n "$CUPSD_BIN" ]] || fail 'cupsd is required to validate the candidate'
}

validate_candidate() {
  local path="$1"

  validate_rendered_policy "$path"
  find_cupsd
  "$CUPSD_BIN" -t -c "$path" >/dev/null 2>&1 \
    || fail 'cupsd rejected the rendered configuration'
}

render_to_temp() {
  local destination="$1"

  [[ -f "$CUPSD_CONF" && ! -L "$CUPSD_CONF" ]] || fail 'cupsd.conf must be a regular file'
  load_policy
  render_candidate "$CUPSD_CONF" "$destination"
  validate_candidate "$destination"
}

dry_run() {
  local candidate

  candidate="$(mktemp)"
  trap 'rm -f "$candidate"' RETURN
  render_to_temp "$candidate"
  if cmp -s "$CUPSD_CONF" "$candidate"; then
    printf 'validation passed; no policy changes are pending\n'
  else
    printf 'validation passed; policy changes are pending (sensitive diff withheld)\n'
  fi
}

prepare_review() {
  local candidate diff_file manifest source_hash source_hash_after candidate_hash diff_status=0

  require_root
  candidate="$(mktemp)"
  diff_file="$(mktemp)"
  manifest="$(mktemp)"
  trap 'rm -f "$candidate" "$diff_file" "$manifest"' RETURN
  [[ -f "$CUPSD_CONF" && ! -L "$CUPSD_CONF" ]] || fail 'cupsd.conf must be a regular file'
  source_hash="$(hash_file "$CUPSD_CONF")"
  render_to_temp "$candidate"
  source_hash_after="$(hash_file "$CUPSD_CONF")"
  [[ "$source_hash" == "$source_hash_after" ]] || fail 'cupsd.conf changed while preparing the review'
  candidate_hash="$(hash_file "$candidate")"

  diff -u --label current --label candidate "$CUPSD_CONF" "$candidate" > "$diff_file" || diff_status=$?
  (( diff_status <= 1 )) || fail 'could not create the review diff'
  printf 'source %s\ncandidate %s\n' "$source_hash" "$candidate_hash" > "$manifest"

  [[ ! -L "$CUPS_REVIEW_DIR" ]] || fail 'review directory must not be a symbolic link'
  install -d -o root -g root -m 700 "$CUPS_REVIEW_DIR"
  install -o root -g root -m 600 "$candidate" "$CUPS_REVIEW_DIR/candidate.conf"
  install -o root -g root -m 600 "$diff_file" "$CUPS_REVIEW_DIR/pending.diff"
  install -o root -g root -m 600 "$manifest" "$CUPS_REVIEW_DIR/manifest"

  printf 'review artifacts prepared with root-only permissions\n'
  printf 'source hash: %s\n' "$source_hash"
  printf 'candidate hash: %s\n' "$candidate_hash"
  printf 'inspect the protected diff outside the LLM transcript, then apply both reviewed hashes\n'
}

verify_review_artifact() {
  local path="$1"
  local expected_mode="$2"

  [[ -f "$path" && ! -L "$path" ]] || fail 'review artifact is missing or unsafe'
  [[ "$(stat_uid "$path")" == 0 ]] || fail 'review artifacts must be owned by root'
  [[ "$(stat_mode "$path")" == "$expected_mode" ]] || fail 'review artifact permissions are unsafe'
}

rollback_config() {
  local backup="$1"

  printf 'apply failed; restoring the previous CUPS configuration\n' >&2
  install -o root -g root -m 640 "$backup" "$CUPSD_CONF"
  systemctl disable --now cups.socket >/dev/null 2>&1 || true
  systemctl enable cups.service >/dev/null 2>&1 || true
  systemctl restart cups.service >/dev/null 2>&1 || true
}

apply_reviewed() {
  local expected_source_hash="$1"
  local expected_candidate_hash="$2"
  local candidate="$CUPS_REVIEW_DIR/candidate.conf"
  local manifest="$CUPS_REVIEW_DIR/manifest"
  local recorded_source_hash recorded_candidate_hash current_source_hash backup
  local socket_exists=false

  require_root
  [[ "$expected_source_hash" =~ ^[a-f0-9]{64}$ ]] || fail 'source hash must be 64 lowercase hexadecimal characters'
  [[ "$expected_candidate_hash" =~ ^[a-f0-9]{64}$ ]] || fail 'candidate hash must be 64 lowercase hexadecimal characters'
  [[ -d "$CUPS_REVIEW_DIR" && ! -L "$CUPS_REVIEW_DIR" ]] || fail 'review directory is missing or unsafe'
  [[ "$(stat_uid "$CUPS_REVIEW_DIR")" == 0 && "$(stat_mode "$CUPS_REVIEW_DIR")" == 700 ]] \
    || fail 'review directory ownership or permissions are unsafe'
  verify_review_artifact "$candidate" 600
  verify_review_artifact "$manifest" 600
  verify_review_artifact "$CUPS_REVIEW_DIR/pending.diff" 600
  [[ -f "$CUPSD_CONF" && ! -L "$CUPSD_CONF" ]] || fail 'cupsd.conf must be a regular file'

  recorded_source_hash="$(awk '$1 == "source" { print $2 }' "$manifest")"
  recorded_candidate_hash="$(awk '$1 == "candidate" { print $2 }' "$manifest")"
  [[ "$recorded_source_hash" =~ ^[a-f0-9]{64}$ && "$recorded_candidate_hash" =~ ^[a-f0-9]{64}$ ]] \
    || fail 'review manifest is invalid'
  [[ "$expected_source_hash" == "$recorded_source_hash" ]] || fail 'provided source hash does not match the reviewed source'
  [[ "$expected_candidate_hash" == "$recorded_candidate_hash" ]] || fail 'provided candidate hash does not match the reviewed candidate'
  current_source_hash="$(hash_file "$CUPSD_CONF")"
  [[ "$current_source_hash" == "$recorded_source_hash" ]] || fail 'cupsd.conf changed after review; prepare a new review'
  [[ "$(hash_file "$candidate")" == "$recorded_candidate_hash" ]] || fail 'reviewed candidate changed after review'
  validate_candidate "$candidate"

  require_command systemctl
  require_command curl
  backup="$CUPSD_CONF.bak.$(date +%Y%m%d%H%M%S)"
  [[ ! -e "$backup" ]] || fail 'backup destination already exists'
  install -o root -g root -m 600 "$CUPSD_CONF" "$backup"
  install -o root -g root -m 640 "$candidate" "$CUPSD_CONF"

  if systemctl cat cups.socket >/dev/null 2>&1; then
    socket_exists=true
  fi
  if [[ "$socket_exists" == true ]] && ! systemctl disable --now cups.socket >/dev/null 2>&1; then
    rollback_config "$backup"
    fail 'could not disable CUPS socket activation'
  fi
  if ! systemctl enable cups.service >/dev/null 2>&1 \
    || ! systemctl restart cups.service >/dev/null 2>&1 \
    || ! curl --fail --silent --show-error --max-time 10 --header 'Host: localhost' http://127.0.0.1:631/ >/dev/null 2>&1; then
    rollback_config "$backup"
    fail 'CUPS restart or local probe failed'
  fi

  rm -f "$candidate" "$CUPS_REVIEW_DIR/pending.diff" "$manifest"
  rmdir "$CUPS_REVIEW_DIR" 2>/dev/null || true
  printf 'reviewed policy applied; cups.service is active and the local probe passed\n'
}

mode="${1:-}"
case "$mode" in
  --dry-run)
    (( $# == 1 )) || { usage; exit 1; }
    dry_run
    ;;
  --prepare-review)
    (( $# == 1 )) || { usage; exit 1; }
    prepare_review
    ;;
  --apply-reviewed)
    (( $# == 3 )) || { usage; exit 1; }
    apply_reviewed "$2" "$3"
    ;;
  *)
    usage
    exit 1
    ;;
esac
