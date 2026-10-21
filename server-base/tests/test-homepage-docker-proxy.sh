#!/usr/bin/env bash
set -euo pipefail

# Live test of the Homepage Docker proxy (server-base/homepage/compose.yml)
# against the real Docker daemon: Homepage gets container status and stats
# through it, and every other Docker API call is refused. Needs docker and
# curl, and loopback ports 2375 and 33000 free.

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
project="hp-proxy-test-$$"
target="hp-proxy-target-$$"
compose=(docker compose -p "$project" -f "$tmp/base/homepage/compose.yml" -f "$tmp/override.yml")

cleanup() {
  "${compose[@]}" down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$target" >/dev/null 2>&1 || true
  docker run --rm -v "$tmp:/t" alpine:3 rm -rf /t/config >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp/base/homepage" "$tmp/config"
cp "$repo/server-base/homepage/compose.yml" "$tmp/base/homepage/"
printf 'TZ=Etc/UTC\n' >"$tmp/base/timezone.env"
cp "$repo/linux-server/homepage/config/docker.yaml" "$tmp/config/"
printf -- '- Test:\n    - target:\n        server: my-docker\n        container: %s\n' "$target" >"$tmp/config/services.yaml"
: >"$tmp/config/settings.yaml"
cat >"$tmp/override.yml" <<EOF
services:
  homepage:
    container_name: $project-homepage
    environment:
      PORT: "33000"
    volumes:
      - $tmp/config:/app/config
  docker-socket-proxy:
    container_name: $project-proxy
EOF

docker run -d --name "$target" alpine:3 sleep 300 >/dev/null
id="$(docker inspect -f '{{.Id}}' "$target")"
"${compose[@]}" up -d --quiet-pull >/dev/null

"${compose[@]}" config --format json | python3 -c '
import json, sys
svcs = json.load(sys.stdin)["services"]
sys.exit(1 if any("docker.sock" in json.dumps(v.get("volumes", [])) for v in [svcs["homepage"]]) else 0)' ||
  fail "homepage still mounts the Docker socket"

for _ in $(seq 1 60); do
  curl -sf -o /dev/null http://127.0.0.1:33000/ && break
  sleep 2
done

status="$(curl -s 'http://127.0.0.1:33000/api/docker/statuses?server=my-docker')"
grep -q "\"$target\":{\"status\":\"running\"" <<<"$status" || fail "status through the proxy: $status"
stats="$(curl -s 'http://127.0.0.1:33000/api/docker/stats?server=my-docker')"
grep -q "\"$target\":{\"cpu\"" <<<"$stats" || fail "stats through the proxy: $stats"

probe() {
  local want="$1" method="$2" path="$3" got
  got="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' -X "$method" "http://127.0.0.1:2375$path")"
  [[ "$got" == "$want" ]] || fail "$method $path: got $got, want $want"
}
probe 200 GET /containers/json
probe 200 GET "/containers/$id/stats?stream=false"
probe 200 GET /v1.44/containers/json
probe 403 GET "/containers/$id/json"
probe 403 GET "/containers/$id/logs?stdout=1"
probe 403 GET "/containers/$id/archive?path=/etc"
probe 403 GET /info
probe 403 GET /images/json
probe 403 GET /secrets
probe 403 GET "/containers/json/../$id/json"
probe 403 GET "/containers/json/..%2f$id/json"
probe 403 GET "/containers/$id/stats/../json"
probe 405 POST /containers/create
probe 405 POST "/containers/$id/exec"
probe 405 POST "/containers/$id/stop"
probe 405 DELETE "/containers/$id"
[[ "$(docker inspect -f '{{.State.Running}}' "$target")" == true ]] || fail "target container was disturbed"

listen="$(docker inspect -f '{{json .Args}}' "$project-proxy")"
grep -q '"-listenip=127.0.0.1"' <<<"$listen" || fail "proxy does not listen on loopback only"
[[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}}' "$project-proxy")" == 'true ["ALL"]' ]] ||
  fail "proxy is not read-only with all capabilities dropped"

printf 'homepage docker proxy tests passed.\n'
