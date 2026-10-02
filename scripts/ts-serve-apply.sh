#!/usr/bin/env bash
# Render a host's Tailscale Serve template and merge it into the live serve
# config. The contract is docs/ONE_NODE_PER_HOST.md section 3.
#
# Usage: scripts/ts-serve-apply.sh <template> [--services all|none|svc:a[,svc:b]] [--dry-run]
#
# Run as the tailscaled operator (sudo tailscale set --operator=$USER) or root.
set -euo pipefail

readonly MIN_VERSION=1.102.3

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'usage: %s <template> [--services all|none|svc:a[,svc:b]] [--dry-run]\n' "${0##*/}"
}

template="" services=all dry_run=false
while (( $# )); do
  case "$1" in
    --dry-run) dry_run=true ;;
    --services)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      services="$2"
      shift
      ;;
    --services=*) services="${1#*=}" ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *)
      [[ -z "$template" ]] || { usage >&2; exit 2; }
      template="$1"
      ;;
  esac
  shift
done
[[ -n "$template" ]] || { usage >&2; exit 2; }
[[ -f "$template" ]] || die "template not found: $template"

command -v jq >/dev/null || die "jq is not installed"
command -v tailscale >/dev/null || die "tailscale is not installed"

# ── Preconditions (read-only) ────────────────────────────────────────────────
version="$(tailscale version)" || die "tailscale version failed"
version="${version%%$'\n'*}"
version="${version%%-*}"
[[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -V | head -n1)" == "$MIN_VERSION" ]] \
  || die "tailscale $version is older than $MIN_VERSION"

status="$(tailscale status --json)" || die "tailscale status --json failed"
[[ "$(jq -r '.BackendState // empty' <<< "$status")" == Running ]] \
  || die "tailscaled BackendState is not Running"
live_cert="$(jq -r '(.Self.DNSName // "") | rtrimstr(".")' <<< "$status")"
live_suffix="$(jq -r '.CurrentTailnet.MagicDNSSuffix // ""' <<< "$status")"

# ── Render values: environment, then <template-dir>/.env, then the live node ─
env_file="$(dirname -- "$template")/.env"
declare -A file_val=()
if [[ -f "$env_file" ]]; then
  dq='^"(.*)"$' sq="^'(.*)'\$" kv='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$' skip='^[[:space:]]*(#.*)?$'
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ $skip ]] && continue
    [[ "$line" =~ $kv ]] || die "$env_file:$n: not a KEY=value line"
    key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    case "$key" in
      TS_CERT_DOMAIN | TS_MAGICDNS_SUFFIX) ;;
      *) die "$env_file:$n: unknown key $key" ;;
    esac
    if [[ "$val" =~ $dq || "$val" =~ $sq ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    file_val[$key]="$val"
  done < "$env_file"
  for key in TS_CERT_DOMAIN TS_MAGICDNS_SUFFIX; do
    [[ -n "${file_val[$key]:-}" ]] || die "$env_file: $key is missing or empty"
  done
fi

fallback=false
# Prints "<value>\t<source>" for one key.
resolve() {
  local key="$1" live="$2"
  if [[ -n "${!key:-}" ]]; then
    printf '%s\t%s\n' "${!key}" "the environment"
  elif [[ -f "$env_file" ]]; then
    printf '%s\t%s\n' "${file_val[$key]}" "$env_file"
  else
    printf '%s\t%s\n' "$live" "tailscale status"
  fi
}
IFS=$'\t' read -r cert cert_src < <(resolve TS_CERT_DOMAIN "$live_cert")
IFS=$'\t' read -r suffix suffix_src < <(resolve TS_MAGICDNS_SUFFIX "$live_suffix")
[[ "$cert_src" == "tailscale status" || "$suffix_src" == "tailscale status" ]] && fallback=true
if [[ "$fallback" == true ]]; then
  printf 'warning: %s not found; using values from tailscale status\n' "$env_file" >&2
fi

suffix_re='^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$'
label_re='^[a-z0-9-]+$'
[[ "$suffix" =~ $suffix_re ]] \
  || die "TS_MAGICDNS_SUFFIX from $suffix_src is not a lower-case <tailnet>.ts.net name"
[[ "$cert" == *.* && "${cert%%.*}" =~ $label_re && "${cert#*.}" == "$suffix" ]] \
  || die "TS_CERT_DOMAIN from $cert_src is not one <host> label followed by .TS_MAGICDNS_SUFFIX"
[[ "$cert" == "$live_cert" ]] \
  || die "TS_CERT_DOMAIN from $cert_src does not match the live node (tailscale status)"
[[ "$suffix" == "$live_suffix" ]] \
  || die "TS_MAGICDNS_SUFFIX from $suffix_src does not match the live node (tailscale status)"

# ── Render (literal replacement of exactly two tokens) ───────────────────────
raw="$(<"$template")"
rendered="${raw//'${TS_CERT_DOMAIN}'/$cert}"
rendered="${rendered//'${TS_MAGICDNS_SUFFIX}'/$suffix}"
[[ "$rendered" != *'${'* ]] || die "$template: a \${...} placeholder is left after rendering"
rendered="$(jq -e . <<< "$rendered" 2>/dev/null)" || die "$template: not valid JSON after rendering"

# ── Validate ─────────────────────────────────────────────────────────────────
# Messages name ports and mounts, never the rendered host names.
# shellcheck disable=SC2016
validate='
def port: sub("^.*:"; "");
def checktcp($scope):
  (.TCP // {}) | to_entries[]
  | (if .key == "5252" then "\($scope): port 5252 is reserved for the web client" else empty end),
    (if .value.TCPForward != null
        and ((.value.TCPForward | tostring | test("^127\\.0\\.0\\.1:[0-9]+$")) | not)
     then "\($scope): TCP \(.key) TCPForward must be 127.0.0.1:<port>" else empty end);
def checkweb($scope):
  (.TCP // {}) as $tcp
  | (.Web // {}) | to_entries[] as $w
  | ($w.key | port) as $p
  | (if ($tcp[$p].HTTPS // false) != true
     then "\($scope): Web :\($p) has no TCP \($p) with HTTPS: true" else empty end),
    (($w.value.Handlers // {}) | to_entries[] as $h
     | ($h.value | keys - ["Proxy"]) as $extra
     | if ($extra | length) > 0
       then "\($scope): handler :\($p)\($h.key) uses \($extra | join(",")); only Proxy is allowed"
       elif (($h.value.Proxy | type) != "string")
         or (($h.value.Proxy | test("^(http|https\\+insecure)://127\\.0\\.0\\.1:[0-9]+(/.*)?$")) | not)
       then "\($scope): handler :\($p)\($h.key) Proxy must be http://127.0.0.1:<port> or https+insecure://127.0.0.1:<port>"
       else empty end);
(keys - ["TCP", "Web", "Services"]
 | if length > 0 then "top-level keys not allowed: \(join(","))" else empty end),
checktcp("node"),
checkweb("node"),
((.Services // {}) | to_entries[] as $s
 | if ($s.key | test("^svc:[a-z0-9-]+$")) | not
   then "Service \($s.key) is not named svc:<name>"
   else ($s.key | ltrimstr("svc:")) as $name
   | ($s.value | checktcp($s.key)),
     ($s.value | checkweb($s.key)),
     (($s.value.Web // {}) | keys[]
      | select((startswith($name + "." + $suffix + ":") and (port | test("^[0-9]+$"))) | not)
      | "\($s.key): Web key :\(port) is not \($name).TS_MAGICDNS_SUFFIX:<port>")
   end)
'
problems="$(jq -r --arg suffix "$suffix" "$validate" <<< "$rendered" 2>/dev/null)" \
  || die "$template: unexpected structure (TCP, Web, Services and Handlers must be objects)"
if [[ -n "$problems" ]]; then
  while IFS= read -r p; do printf 'error: %s: %s\n' "$template" "$p" >&2; done <<< "$problems"
  exit 1
fi

# ── Pick the Services this run owns ──────────────────────────────────────────
mapfile -t tpl_services < <(jq -r '.Services // {} | keys[]' <<< "$rendered")
picked=()
case "$services" in
  all) picked=("${tpl_services[@]}") ;;
  none) ;;
  *)
    IFS=, read -ra picked <<< "$services"
    for s in "${picked[@]}"; do
      [[ " ${tpl_services[*]} " == *" $s "* ]] || die "--services: $s is not in $template"
    done
    ;;
esac
picked_json="$(jq -nc '$ARGS.positional' --args "${picked[@]}")"
if (( ${#picked[@]} )); then
  jq -e '(.Self.Tags // []) | length > 0' <<< "$status" >/dev/null \
    || die "Services need a tagged host; this node has no tags (docs/ONE_NODE_PER_HOST.md D8)"
fi

# ── Merge into the current config ────────────────────────────────────────────
read_serve() {
  local out
  out="$(tailscale serve status --json)" || die "tailscale serve status --json failed"
  [[ -n "${out//[[:space:]]/}" ]] || out='{}'
  jq -e 'if . == null then {} else . end | objects' <<< "$out" 2>/dev/null \
    || die "tailscale serve status --json did not print a JSON object"
}
current="$(read_serve)"

# shellcheck disable=SC2016
owned_def='
def owned($tpl; $picked): {
  TCP: ((.TCP // {}) | with_entries(select(.key as $k | ($tpl.TCP // {}) | has($k)))),
  Web: ((.Web // {}) | with_entries(select(.key as $k | ($tpl.Web // {}) | has($k)))),
  Services: ((.Services // {}) | with_entries(select(.key as $k | any($picked[]; . == $k))))
};
def kind: if .HTTPS == true then "HTTPS" elif .HTTP == true then "HTTP"
  elif (.TCPForward // "") != "" then "TCPForward" else "other" end;
'
# jqm [jq flags...] <filter>: jq with $tpl, $picked and the helpers above.
jqm() {
  jq "${@:1:$#-1}" --argjson tpl "$rendered" --argjson picked "$picked_json" "$owned_def ${*: -1}"
}

# shellcheck disable=SC2016
conflicts="$(jqm -r '
  . as $cur
  | (($tpl.TCP // {}) | to_entries[]
     | select($cur.TCP[.key] != null and ($cur.TCP[.key] | kind) != (.value | kind))
     | "node port \(.key) is \($cur.TCP[.key] | kind), the template wants \(.value | kind)"),
    ($picked[] as $s
     | ($tpl.Services[$s].TCP // {}) | to_entries[]
     | select($cur.Services[$s].TCP[.key] != null
              and ($cur.Services[$s].TCP[.key] | kind) != (.value | kind))
     | "\($s) port \(.key) is \($cur.Services[$s].TCP[.key] | kind), the template wants \(.value | kind)")
' <<< "$current")"
if [[ -n "$conflicts" ]]; then
  while IFS= read -r c; do printf 'error: %s; remove that listener by hand first\n' "$c" >&2; done <<< "$conflicts"
  exit 1
fi

# shellcheck disable=SC2016
merged="$(jqm '
  def put($k; $v): if ($v | length) > 0 then .[$k] = ((.[$k] // {}) + $v) else . end;
  put("TCP"; $tpl.TCP // {})
  | put("Web"; $tpl.Web // {})
  | put("Services"; ($tpl.Services // {}) | with_entries(select(.key as $k | any($picked[]; . == $k))))
' <<< "$current")"

if [[ "$(jq -S . <<< "$merged")" == "$(jq -S . <<< "$current")" ]]; then
  printf 'up to date\n'
  exit 0
fi

if [[ "$dry_run" == true ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  jq -S . <<< "$current" > "$work/current.json"
  jq -S . <<< "$merged" > "$work/merged.json"
  printf '==> Rendered template (%s)\n%s\n' "$template" "$rendered"
  printf '\n==> Owned keys\n'
  jq -r '(.TCP // {} | keys[] | "TCP \(.)"), (.Web // {} | keys[] | "Web \(.)")' <<< "$rendered"
  if (( ${#picked[@]} )); then printf 'Services %s\n' "${picked[@]}"; fi
  printf '\n==> Preserved keys\n'
  # shellcheck disable=SC2016
  jqm -r '
    (keys[] | select(. != "TCP" and . != "Web" and . != "Services")),
    ((.TCP // {}) | keys[] as $k | select(($tpl.TCP // {}) | has($k) | not) | "TCP \($k)"),
    ((.Web // {}) | keys[] as $k | select(($tpl.Web // {}) | has($k) | not) | "Web \($k)"),
    ((.Services // {}) | keys[] as $k | select(any($picked[]; . == $k) | not) | "Services \($k)")
  ' <<< "$current"
  printf '\n==> Diff (current -> merged)\n'
  diff -u --label current --label merged "$work/current.json" "$work/merged.json" || true
  printf '\n==> Would run\n  tailscale serve set-raw < <merged config>\n'
  for s in "${picked[@]}"; do printf '  tailscale serve advertise %s\n' "$s"; done
  printf '\nDry run: nothing was written.\n'
  exit 0
fi

# ── Write, advertise, read back ──────────────────────────────────────────────
tailscale serve set-raw <<< "$merged" || die "tailscale serve set-raw failed"
for s in "${picked[@]}"; do
  tailscale serve advertise "$s" || die "tailscale serve advertise $s failed"
done

after="$(read_serve)"
# shellcheck disable=SC2016
jq -e --argjson after "$after" --argjson tpl "$rendered" --argjson picked "$picked_json" \
  "$owned_def"' ($after | owned($tpl; $picked)) == owned($tpl; $picked)' <<< "$merged" >/dev/null \
  || die "read-back: tailscale serve status --json does not match the rendered template"
printf 'applied %s\n' "$template"
