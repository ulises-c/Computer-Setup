#!/usr/bin/env bash
set -euo pipefail

# Live test of Homepage's Docker access (server-base/homepage/compose.yml)
# against the real Docker daemon. Homepage gets container status and stats
# through the filtered proxy socket; every other Docker API call is refused,
# only root can open that socket, the running Homepage holds no Docker socket,
# and stopping the proxy fails closed. Needs docker; uses loopback port 33000.

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
project="hp-proxy-test-$$"
target="hp-proxy-target-$$"
curl_image="curlimages/curl:8.11.1"
compose=(docker compose -p "$project" -f "$tmp/base/homepage/compose.yml" -f "$tmp/override.yml")

cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
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
      HOSTNAME: "0.0.0.0"
      HOMEPAGE_ALLOWED_HOSTS: "lan-name.test:33000"
    volumes:
      - $tmp/config:/app/config
  docker-socket-proxy:
    container_name: $project-proxy
EOF

docker run -d --name "$target" alpine:3 sleep 600 >/dev/null
id="$(docker inspect -f '{{.Id}}' "$target")"
"${compose[@]}" up -d --quiet-pull >/dev/null
volume="${project}_homepage-docker"

mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$project-homepage")"
[[ "$mounts" != *docker.sock* ]] || fail "running homepage mounts the Docker socket: $mounts"

for _ in $(seq 1 60); do
  curl -sf -o /dev/null http://127.0.0.1:33000/ && break
  sleep 2
done

status="$(curl -s 'http://127.0.0.1:33000/api/docker/statuses?server=my-docker')"
grep -q "\"$target\":{\"status\":\"running\"" <<<"$status" || fail "status through the proxy: $status"
stats="$(curl -s 'http://127.0.0.1:33000/api/docker/stats?server=my-docker')"
grep -q "\"$target\":{\"cpu\"" <<<"$stats" || fail "stats through the proxy: $stats"

lan="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: lan-name.test:33000' http://127.0.0.1:33000/)"
[[ "$lan" == 200 ]] || fail "direct LAN Host header with port: got $lan"

# Hosts that expose Homepage on the LAN must allow their LAN names with the port.
for host_dir in linux-server linux-pi; do
  allowed="$(grep -o 'HOMEPAGE_ALLOWED_HOSTS: .*' "$repo/$host_dir/homepage/docker-compose.yml")"
  port="$(grep -o 'PORT: "[0-9]*"' "$repo/$host_dir/homepage/docker-compose.yml" | grep -o '[0-9]*' || printf 3000)"
  grep -q 'HOSTNAME: "0.0.0.0"' "$repo/$host_dir/homepage/docker-compose.yml" || continue
  [[ "$allowed" =~ \}:$port, ]] || fail "$host_dir: LAN entries in HOMEPAGE_ALLOWED_HOSTS lack :$port"
done

# One curl container runs every probe and prints "<code> <method> <path>".
probes=(
  "200 GET /containers/json"
  "200 GET /containers/json?all=true"
  "200 GET /v1.44/containers/json"
  "200 GET /containers/$id/stats?stream=false"
  "403 GET /containers/$id/json"
  "403 GET /containers/$id/logs?stdout=1"
  "403 GET /containers/$id/archive?path=/etc"
  "403 GET /info"
  "403 GET /images/json"
  "403 GET /secrets"
  "403 GET /containers/json/../$id/json"
  "403 GET /containers/json/..%2f$id/json"
  "403 GET /containers/json%3F/../../info"
  "403 GET //containers/$id/json"
  "403 GET /containers/$id/stats/../json"
  "405 POST /containers/create"
  "405 POST /containers/$id/exec"
  "405 POST /containers/$id/stop"
  "405 DELETE /containers/$id"
)
# shellcheck disable=SC2016
script='for p in "$@"; do set -- $p; printf "%s %s %s\n" "$(curl -s --path-as-is -o /dev/null -w "%{http_code}" --unix-socket /s/docker.sock -X "$2" "http://d$3")" "$2" "$3"; done'
results="$(docker run --rm --user 0 -v "$volume:/s:ro" --entrypoint sh "$curl_image" -c "$script" sh "${probes[@]}")"
mapfile -t got <<<"$results"
for i in "${!probes[@]}"; do
  [[ "${got[$i]:-}" == "${probes[$i]}" ]] || fail "proxy probe: got '${got[$i]:-}', want '${probes[$i]}'"
done
[[ "$(docker inspect -f '{{.State.Running}}' "$target")" == true ]] || fail "target container was disturbed"

nonroot="$(docker run --rm --user 1000 -v "$volume:/s:ro" "$curl_image" -s -o /dev/null -w '%{http_code}' --unix-socket /s/docker.sock http://d/containers/json || true)"
[[ "$nonroot" == 000 ]] || fail "a non-root client reached the proxy socket: $nonroot"

[[ "$(docker inspect -f '{{.HostConfig.NetworkMode}} {{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}}' "$project-proxy")" == 'none true ["ALL"]' ]] ||
  fail "proxy is not network-less, read-only and without capabilities"

docker stop -t 5 "$project-proxy" >/dev/null
down="$(curl -s 'http://127.0.0.1:33000/api/docker/statuses?server=my-docker')"
if grep -q "\"$target\"" <<<"$down"; then
  fail "homepage still reads Docker with the proxy stopped: $down"
fi

printf 'homepage docker proxy tests passed.\n'
