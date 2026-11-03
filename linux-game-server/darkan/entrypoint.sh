#!/usr/bin/env bash
set -euo pipefail

kind="${1:?usage: darkan-entrypoint lobby|world}"
case "$kind" in
  lobby|world) ;;
  *) printf 'error: unknown server kind: %s\n' "$kind" >&2; exit 2 ;;
esac

[[ -d /state && -w /state ]] || { printf 'error: /state is not a writable mount\n' >&2; exit 2; }
export HOME=/state

# shellcheck disable=SC2086
exec java ${DARKAN_JAVA_OPTS:-} -jar "/opt/darkan/$kind-server.jar"
