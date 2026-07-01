#!/usr/bin/env bash
# Schema validator for packages.json. Enforces the invariants the install
# engine relies on but cannot check at runtime — most importantly the
# "no silent drop" rule: every platform listed in a package's package_manager
# must resolve to a valid priority tier and a boolean optional, so a typo'd or
# missing per-platform key fails here at commit time instead of silently
# dropping the package from every install.
#
# Validates:
#   - package_manager is an object; its keys are known platforms
#   - per-platform priority/optional/environment/install_command objects only
#     key platforms that the package actually targets
#   - every targeted platform resolves a valid priority (high/medium/low/none)
#     and a boolean optional (scalar or per-platform object form both allowed)
#   - environment is a tag array (legacy) or a per-platform object of tag arrays
#   - tags is a non-empty array drawn from the controlled vocabulary
#
# Usage: bash scripts/validate-packages.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${1:-$ROOT/packages.json}"

command -v jq >/dev/null || { printf 'error: jq is required\n' >&2; exit 1; }

if ! jq empty "$PKG" 2>/dev/null; then
  printf 'error: %s is not valid JSON\n' "$PKG" >&2
  exit 1
fi

if ! jq -e 'type == "array"' "$PKG" >/dev/null 2>&1; then
  printf 'error: %s top-level value must be a JSON array\n' "$PKG" >&2
  exit 1
fi

# shellcheck disable=SC2016  # $vars below are jq variables, not shell expansions
errors=$(jq -r '
  def PLATFORMS: ["macos","ubuntu","arch","server"];
  def TIERS: ["high","medium","low","none"];
  def ENVS: ["work","personal"];
  def TAGS: ["ai-coding","benchmarking","browser","cloud-storage","communication",
             "containers","database","desktop-utility","development","entertainment",
             "local-llm","media","networking","photos","productivity","science",
             "security","system-monitoring","terminal"];
  def prfor($p): (.priority | if type == "object" then .[$p] else . end);
  def optfor($p): (.optional | if type == "object" then .[$p] else . end);
  def icfor($p): (.install_command | if type == "object" then .[$p] else . end);

  ( group_by(.name)[] | select(length > 1)
      | "duplicate name \"\(.[0].name // "(unnamed)")\" — \(length) entries" ),
  ( to_entries[]
  | .key as $i | .value as $e
  | ($e.name // "<unnamed #\($i)>") as $nm
  | $e
  | [
      (if (.name | type) != "string" or (.name | length) == 0
        then "<entry #\($i)>: name must be a non-empty string" else empty end),

      (if (.package_manager | type) != "object"
        then "\($nm): package_manager must be an object"
       elif (.package_manager | length) == 0
        then "\($nm): package_manager must list at least one platform"
       else empty end),

      (if (.package_manager | type) == "object"
        then ((.package_manager | keys[]) as $k
              | if (PLATFORMS | index($k)) == null
                then "\($nm): unknown platform \"\($k)\" in package_manager" else empty end)
        else empty end),

      (["priority","optional","environment","install_command"][] as $f
        | .[$f] as $v
        | if ($v | type) == "object" and (.package_manager | type) == "object"
          then (($v | keys[]) as $k
                | if ((.package_manager | keys) | index($k)) == null
                  then "\($nm): \($f) keys platform \"\($k)\" not in package_manager" else empty end)
          else empty end),

      (if (.package_manager | type) == "object"
        then ((.package_manager | keys[]) as $p
              | (prfor($p) as $pr
                  | if (TIERS | index($pr)) == null
                    then "\($nm): priority for \"\($p)\" is \($pr | tojson) — must be high/medium/low/none" else empty end),
                (optfor($p) as $o
                  | if ($o | type) != "boolean"
                    then "\($nm): optional for \"\($p)\" is \($o | tojson) — must be boolean" else empty end))
        else empty end),

      (.handled_by_setup as $h
        | if $h == null or ($h | type) == "boolean" then empty
          else "\($nm): handled_by_setup is \($h | tojson) — must be boolean (the engine tests == true)" end),

      (if (.package_manager | type) == "object"
        then ((.package_manager | to_entries[]) as $kv
              | if $kv.value == "custom" and (icfor($kv.key) | type) != "string"
                then "\($nm): custom on \"\($kv.key)\" needs a string install_command (got \(icfor($kv.key) | tojson))"
                else empty end)
        else empty end),

      (.environment as $env
        | if $env == null then empty
          elif ($env | type) == "array"
            then ($env[] as $x
                  | if (ENVS | index($x)) == null
                    then "\($nm): environment value \"\($x)\" — must be work/personal" else empty end)
          elif ($env | type) == "object"
            then (($env | to_entries[]) as $kv
                  | if ($kv.value | type) != "array"
                    then "\($nm): environment.\($kv.key) must be an array"
                    else ($kv.value[] as $x
                          | if (ENVS | index($x)) == null
                            then "\($nm): environment.\($kv.key) value \"\($x)\" — must be work/personal" else empty end)
                    end)
          else "\($nm): environment must be a tag array or per-platform object" end),

      (if (.tags | type) != "array" then "\($nm): tags must be an array"
       elif (.tags | length) == 0 then "\($nm): tags must be non-empty"
       else (.tags[] as $tg
             | if (TAGS | index($tg)) == null
               then "\($nm): unknown tag \"\($tg)\" — not in the controlled vocabulary" else empty end)
       end)
    ]
  | .[] )
' "$PKG")

if [[ -n "$errors" ]]; then
  printf '%s\n' "$errors" >&2
  printf '\nvalidate-packages: FAILED\n' >&2
  exit 1
fi

printf 'validate-packages: PASSED (%d entries)\n' "$(jq length "$PKG")"
