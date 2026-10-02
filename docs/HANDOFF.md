# Session Handoff

Scratchpad for in-progress work that spans more than one session — live
infrastructure state, decisions made outside of code, and what's next.
Branch-specific; delete or trim entries once they're fully landed and the
branch merges.

## #86 install: one tailnet node per host

Status: the code is done and reviewed in PR #102 (branch
`feat/86-one-node-per-host`). **Nothing has been installed.** This entry is
the runbook for the agent that does the install on the server. The design and
the reasons behind each step are in
[ONE_NODE_PER_HOST.md](ONE_NODE_PER_HOST.md), cited as "design §n" or Dn.
A bare §n is a section of this file. This file is
the executable copy of design §4. It also adds these checks, which the design
doesn't have: the ACL gate before tagging (§0.1 step 1), per-stack `.env`
copies for rollback (§1 step 7, §1.1), stopping qBittorrent before its config
edit, rendering `cockpit.conf` from the example, and the scripted probe (§4).
If this file and the design disagree on a value (a port, a name, an order),
stop and ask.

Each host ends up as one tailnet node. Its web services are published by host
`tailscale serve` from `<host-dir>/tailscale-serve/serve.json` via
`scripts/ts-serve-apply.sh`, and there are no per-service `<svc>-ts` sidecars.

### Conventions

- **HUMAN** marks a step that needs the Tailscale admin console, a router, a
  phone or a browser login. Stop at it, ask the user to do it, and wait for
  them to confirm. Never guess it was done.
- **DESTRUCTIVE** marks a step that removes a node, a container or state.
  Don't run it unless every check before it has passed.
- **STOP** means: if the expected result doesn't appear, do not improvise.
  Leave the system as it is, report the step and its output, and wait.
- Placeholders: `<repo>` is the checkout on the host (the server's is where
  `setup.sh --profile server` ran). `<server>.<tailnet>.ts.net` and
  `<pi-hostname>.<tailnet>.ts.net` are the host nodes' MagicDNS names, and
  `<tailnet>.ts.net` is the MagicDNS suffix. `<server-ip>` and `<pi-lan-ip>`
  are LAN IPs. `<backup-dir>` is a new root-owned directory per run, for
  example `/root/cs86-backup-<date>`.
- Read the real names from the node and keep them in shell variables. Never
  write them into tracked files:

  ```sh
  NODE=$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')
  SUFFIX=$(tailscale status --json | jq -r '.CurrentTailnet.MagicDNSSuffix')
  ```

- Secrets: never print a `.env` file, a token, an auth key or a password into
  chat, logs, commits or this file. To inspect a `.env`, list key names only:
  `grep -oE '^[A-Z_][A-Z0-9_]*=' .env`. Use these helpers to edit one key
  without echoing values:

  ```sh
  setenv() { local f="$1" k="$2" v="$3"
    if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else printf '%s=%s\n' "$k" "$v" >> "$f"; fi; }
  getkeys() { grep -oE '^[A-Z_][A-Z0-9_]*=' "$1" | tr -d = | paste -sd' '; }
  ```

- Do not commit, push, delete branches or edit tracked files on the hosts.
  Per-stack rollback (`git checkout <pre-migration-commit> -- <path>`) is the
  only allowed working-tree change; record it when you use it.
- Never run `tailscale funnel`: everything here is tailnet-only. Never run
  `tailscale serve reset` except in the §5.3 whole-host rollback.
- Keep a progress log outside the repo, for example `~/cs86-install.log`,
  holding step ids, pass/fail and deviations, with no secret values.

### 0. Prerequisites

| What | Check | Expected |
|---|---|---|
| Branch | On the server and on the Pi: `git -C <repo> fetch origin && git -C <repo> rev-parse origin/feat/86-one-node-per-host` | Equals the approved head named in the install prompt, which is also `gh pr view 102 -R ulises-c/Computer-Setup --json headRefOid -q .headRefOid`. A different commit: STOP |
| Signed head | `git -C <repo> log -1 --format='%G? %h' origin/feat/86-one-node-per-host` | `G`, or `E` when the signing key isn't imported on that host. The SHA match in the row above is the gate |
| Clean checkout | `git -C <repo> status --porcelain` | Empty. Ignored files (`.env`, `ts-state/`, app data) are expected and not listed |
| Tailscale floor | `tailscale version` on the server and on the Pi | `1.102.3` or later; `ts-serve-apply.sh` enforces this |
| Tools | `command -v jq docker curl ss` on both hosts | Four paths. Install `jq` if missing (`sudo apt install jq`) |
| Daemon | `tailscale status --json \| jq -r .BackendState` | `Running` |
| Operator | `tailscale serve status --json >/dev/null && echo ok` as the normal user | `ok`. If permission is denied: `sudo tailscale set --operator=$USER` |
| Admin access | HUMAN | The user can open the admin console as Owner or Admin (Access controls, Machines, Services, DNS, Settings → Keys / OAuth clients) |
| Escape hatch | HUMAN | The user can reach the server without the tailnet (LAN SSH or a local console). Tagging (§0.1 step 4) and the cutover can cut tailnet access |
| Pi access | `ssh <pi-lan-ip> true` from the server, or a separate session on the Pi | Works. The Pi has its own checkout of this repo |

If any row fails: STOP.

### 0.1 Admin console, before either host (HUMAN; design §4.1, D5, D8)

1. **ACL gate (do this before tagging).** In Access controls, find the rule
   that lets members reach today's `tag:container` sidecars and the server
   (SSH, Cockpit `:9090`, Syncthing, DNS). Tagging a node removes its user
   identity, so a rule written as `autogroup:member` → member-owned devices
   or `autogroup:self` stops matching it. Check that the policy is
   allow-all, or add `tag:server` and `tag:pi` to the destination of the same
   rule that covers `tag:container`. If it uses Tailscale SSH rules, add a
   matching `ssh` entry for `tag:server`/`tag:pi`. Use **Preview rules** for
   the user against the server to confirm SSH and `:443` stay allowed.
2. **tagOwners.** Add `tag:server` and `tag:pi` with the same owners as the
   existing `tag:container` entry. Leave `tag:container` until §6.
3. **DNS page.** Record every global nameserver. On the server:
   `docker exec adguard-ts tailscale ip -4`; on the Pi:
   `docker exec adguard-pi-ts tailscale ip -4`. If a nameserver equals one of
   those IPs, repoint it now to that host node's tailnet IP
   (`tailscale ip -4` on the host). The sidecar is about to go away.
4. **Tag the server.** Machines page → the server's host node (not a `-ts`
   container) → Edit ACL tags → `tag:server`. Then disable key expiry for it.
   This does not re-authenticate, so the node's IP and device ID stay the same.
   Confirm on the server: `tailscale status --json | jq -r '.Self.Tags[]'`
   prints `tag:server`, and an SSH session from another tailnet device still
   connects. If SSH is refused, fix the ACL (step 1) before going on; STOP.

The Service ACL entries come later, one per Service (§2.3 step 9).

### 1. Server: pre-flight (design §4.2)

Run these on the server, in `<repo>`, as the operator user unless the step
says `sudo`.

1. Record `git rev-parse HEAD` as `<pre-migration-commit>` in the log. It is
   the commit the checkout is on now, normally `main`.
2. `tailscale serve status --json`. Expected: `{}` or empty. Anything else
   must survive the migration; record the keys
   (`jq -r 'paths(scalars) | map(tostring) | join(".")'`) and check them again
   after every apply.
3. The backend ports in design §2.2 must be free or held by their owner:

   ```sh
   for p in 2222 3300 8100 8101 8102 8103 8104 8105 8443 8444 8445 8446 8447 8448 8449; do
     ss -ltnH "sport = :$p" | grep -q . && printf 'BUSY %s\n' "$p"; done; echo checked
   ```

   Expected: only `checked`. Then `ss -ltnpH 'sport = :81'` shows
   nginx-proxy-manager (docker-proxy), and the other design §2.2 backends (3000,
   3001, 3030, 8080, 8088, 8097, 8384, 9000, 9090, 61208) are absent or held
   by the service the table names. STOP on an unknown owner.
4. Units the backup scripts read exist:
   `systemctl cat backup.service >/dev/null && ls ~/.config/systemd/user/tailscale-web.service`.
   Expected: the unit path. STOP if `backup.service` is missing; set it up
   with `linux-server/backup/README.md` first.
5. The LAN IP for NPM (D7): `ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+'`.
   HUMAN: confirm that address is a DHCP reservation or static, because NPM
   refuses to start at boot if it is not on the host.
6. On the Pi, check that the server's name resolves:
   `getent hosts <server>.<tailnet>.ts.net` on the host, and
   `docker exec adguardhome-sync nslookup <server>.<tailnet>.ts.net`. Expected:
   an address in both. If not, fix the Pi's resolver before §2.3 step 5, or
   STOP.
7. Back up the Pi `.env` files that the server steps edit (§2.3 steps 5–6),
   on the Pi, into a new root-owned directory `<pi-env-backup-dir>`:

   ```sh
   sudo bash -euo pipefail -c 'B="$1"; R="$2"; mkdir -m 700 -- "$B"; cd "$R"
   cp -a --parents linux-pi/*/.env "$B/"; ls "$B/linux-pi" | wc -l' _ <pi-env-backup-dir> <repo>
   ```

   Expected: a count of 1 or more, with `adguardhome-sync` and `backup`
   among the copied dirs.

### 1.1 Server: backups (design §4.2 step 6)

`<backup-dir>`'s parent must exist, and `<backup-dir>` itself must not. The
capture is fail-closed: `capture-complete` is written only if every line
succeeded.

```sh
sudo bash -euo pipefail -c 'B="$1"; R="$2"
mkdir -m 700 -- "$B"
systemctl start backup.service
cd "$R/linux-server"
tar -czf "$B/ts-state-server.tgz" -- */ts-state
out=$(tailscale serve status --json)
[[ -n "$out" ]] || out="{}"
jq -e "if . == null then {} else . end | objects" <<< "$out" > "$B/serve-before.json"
if [[ "$(jq length "$B/serve-before.json")" == 0 ]]; then printf "empty\n"; else printf "config\n"; fi > "$B/serve-before.state"
rc=0; tailscale serve get-config --all "$B/serve-services-before.json" || rc=$?
printf "%s\n" "$rc" > "$B/serve-services-before.rc"
if [[ -e /etc/cockpit/cockpit.conf ]]; then cp -a /etc/cockpit/cockpit.conf "$B/"; else : > "$B/cockpit.conf.absent"; fi
home=$(getent passwd "${SUDO_USER:?}" | cut -d: -f6)
cp -a "$home/.config/systemd/user/tailscale-web.service" "$B/"
: > "$B/capture-complete"' _ <backup-dir> <repo>
```

Check it. Do not continue unless it prints `backup-ok`:

```sh
sudo bash -euo pipefail -c 'B="$1"
[[ "$(stat -c "%a %U" "$B")" == "700 root" ]]
[[ -f "$B/capture-complete" ]]
[[ "$(systemctl show -p Result --value backup.service)" == success ]]
[[ "$(tar -tzf "$B/ts-state-server.tgz")" == */ts-state/* ]]
n=$(jq -e "objects | length" "$B/serve-before.json")
state=$(<"$B/serve-before.state")
[[ ( "$state" == empty && "$n" == 0 ) || ( "$state" == config && "$n" != 0 ) ]]
[[ -f "$B/cockpit.conf" || -f "$B/cockpit.conf.absent" ]]
[[ -s "$B/tailscale-web.service" ]]
printf "backup-ok\n"' _ <backup-dir>
```

Then take a per-stack `.env` copy, which the per-stack rollback uses (§5.1):

```sh
sudo bash -euo pipefail -c 'B="$1"; R="$2"; mkdir -m 700 -- "$B/env"; cd "$R"
cp -a --parents linux-server/*/.env "$B/env/"; ls "$B/env/linux-server" | wc -l' _ <backup-dir> <repo>
```

If any script stops, fix the cause and rerun all three with a new
`<backup-dir>`.

### 1.2 Server: switch the checkout and the render `.env` (design §4.2 steps 7–8)

1. `git -C <repo> checkout feat/86-one-node-per-host`, and check that
   `git -C <repo> rev-parse HEAD` equals the approved head. Running containers
   don't change until their stack is brought up again. Two things read the
   checkout live:
   - Homepage reloads `config/services.yaml` at once. Cards for stacks not cut
     over yet return 502 until their step; that is expected.
   - `forgejo/runner-status.sh` now defaults to loopback `:3300`, which has no
     listener until the forgejo cutover. Keep it on the old URL for now:
     `setenv linux-server/forgejo/.env FORGEJO_RUNNER_API_URL "https://forgejo.$SUFFIX/api/v1/admin/actions/runners"`.
2. Create the render `.env` as the operator user:

   ```sh
   cd <repo>/linux-server/tailscale-serve
   (umask 077; tailscale status --json | jq -r '"TS_CERT_DOMAIN=\(.Self.DNSName | rtrimstr("."))\nTS_MAGICDNS_SUFFIX=\(.CurrentTailnet.MagicDNSSuffix)"' > .env)
   cd <repo>
   ```

   Expected: `getkeys linux-server/tailscale-serve/.env` prints
   `TS_CERT_DOMAIN TS_MAGICDNS_SUFFIX`, and `stat -c %a` prints `600`.

### 2. Server: `.env` changes per stack (names only)

Edit each stack's `.env` in its own cutover step below, not all at once.
`TS_AUTHKEY` stays in every `.env` until §6, because rollback needs it; the
new compose files ignore it.

| Stack (`linux-server/…`) | Set or change | Remove now | When |
|---|---|---|---|
| `nginx-proxy-manager` | `NPM_BIND_IP` = the LAN IP from §1 step 5 | — | §2.3 step 1 |
| `homepage` | `HOMEPAGE_VAR_HOMEPAGE_DOMAIN` = `$NODE`, `TAILSCALE_HOSTNAME` = `$NODE`. Keep `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` at its old value until §3 step 7. Keep `HOMEPAGE_VAR_FORGEJO_DOMAIN`, `_NTFY_DOMAIN`, `_IMMICH_DOMAIN`, `_GAME_HOMEPAGE_DOMAIN` | `HOMEPAGE_VAR_{PORTAINER,UPTIMEKUMA,SPEEDTEST,OPENSPEEDTEST,FILEBROWSER,SYNCTHING,GLANCES,PEANUT,ADGUARD,COCKPIT,ATVLOADLY,QBITTORRENT,TAILSCALE_WEB,NPM}_DOMAIN` | §2.3 step 3 |
| `glances` | `GLANCES_ALLOWED_HOSTS`: replace the old `glances.<tailnet>.ts.net` entry with `$NODE` | — | §2.3 step 3 |
| `speedtest-tracker` | `APP_URL` and `ASSET_URL` = `https://$NODE:8445` | — | §2.3 step 4 |
| `adguard` (DNS watchdog) | `KUMA_PUSH_URL`: host → `http://127.0.0.1:3001` (keep `/api/push/<token>`); `NTFY_URL` = `http://127.0.0.1:8103` | — | after uptime-kuma, after ntfy |
| `backup` | `KUMA_PUSH_URL` host → `http://127.0.0.1:3001`; `NTFY_URL` = `http://127.0.0.1:8103` | — | after uptime-kuma, after ntfy |
| `forgejo` | `KUMA_PUSH_URL` host → `http://127.0.0.1:3001`; `NTFY_URL` = `http://127.0.0.1:8103`. `FORGEJO_DOMAIN` unchanged | `FORGEJO_RUNNER_API_URL` (the temporary override from §1.2) | after uptime-kuma, after ntfy, after forgejo |
| `ups` | `NTFY_URL` = `http://127.0.0.1:8103` | — | after ntfy |
| `dragonwilds` | `NTFY_URL` = `http://127.0.0.1:8103` | — | after ntfy |
| `ntfy`, `immich`, `filebrowser`, `qbittorrent`, `watchtower` | — (`NTFY_BASE_URL` unchanged) | — | — |
| `tailscale-serve` | `TS_CERT_DOMAIN`, `TS_MAGICDNS_SUFFIX` (§1.2) | — | §1.2 |
| `~/.config/tailscale-web.env` (user file) | `TAILSCALE_WEB_ORIGIN` = `https://$NODE` | — | §2.3 step 3 |

For a push URL, change only the scheme and host, and keep the token. The
helper does nothing if the key is unset or empty, and never prints the token:

```sh
pushloop() { local f="$1" old
  old=$(grep -oP '^KUMA_PUSH_URL=\K.*' "$f" | tail -1 | tr -d "\"'" || true)
  [[ "$old" == */api/push/* ]] && setenv "$f" KUMA_PUSH_URL "http://127.0.0.1:3001/api/push/${old##*/api/push/}"; true; }
```

Pi `.env` files edited during the server cutover (on the Pi):
`linux-pi/adguardhome-sync/.env` `ORIGIN_URL` = `https://<server>.<tailnet>.ts.net:8443`, and
`linux-pi/backup/.env` `KUMA_PUSH_URL` = `https://<server>.<tailnet>.ts.net:8444/api/push/<token>` (same token).

### 2.1 What one stack step means

For stack `<s>`, with the `.env` already edited:

```sh
cd <repo>/linux-server/<s>
docker compose config -q                 # expected: no output, rc 0
docker compose up -d --remove-orphans    # removes the old <s>-ts sidecar (DESTRUCTIVE: container only; ts-state/ stays)
docker ps -a --format '{{.Names}}' | grep -x -- "<sidecar>"   # expected: no output
```

Then run the host checks and the probe for `<s>` (§4). For the three
Services, the probe passes only after §2.3 step 9.6. STOP on a mismatch, and
either fix it or roll back that stack (§5.1) before starting the next one.

### 2.2 Server: apply the node-level serve config (design §3.5)

```sh
cd <repo>
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none --dry-run
```

Expected: rc 0, no `error:` lines, and `==> Would run` lists only
`tailscale serve set-raw < <merged config>`. The diff adds `TCP` 443 and
8443–8448 and the `<node>:443` … `<node>:8448` `Web` entries. **Preserved
keys** lists anything from §1 step 2. Read the whole diff; STOP if it removes
anything you did not expect. Then:

```sh
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none   # expected: up to date
```

Expected: `applied …`, then `up to date`. A non-zero exit or
`read-back: … does not match`: STOP, then roll back with §5.3.

### 2.3 Server: cutover order (design §4.3)

1. **nginx-proxy-manager** (D7). Set `NPM_BIND_IP`, then run a stack step
   (sidecar `nginx-proxy-manager-ts`). Expected:
   `ss -ltnH 'sport = :443'` shows only `<lan-ip>:443`, and
   `ss -ltnH 'sport = :81'` shows `<lan-ip>:81` and `127.0.0.1:81`. It must go
   before §2.2, so that NPM no longer holds `0.0.0.0:443` when serve starts.
2. **Node-level serve**: §2.2. From now on every new front door answers. A
   stack that isn't cut over yet gives 502, and old sidecar URLs keep working
   in parallel.
3. **Host-networked services**:
   - `glances`: `.env`, then a stack step (`glances-ts`).
   - `ups`: a stack step (`peanut-ts`).
   - `homepage`: `.env`, then a stack step (`homepage-ts`). Use
     `up -d`, not `restart`, because `env_file` is read only at create.
     `docker exec homepage printenv HOMEPAGE_VAR_HOMEPAGE_DOMAIN | grep -c ts.net`
     prints `1`.
   - `cockpit` (its stack is deleted on the branch):

     ```sh
     sed "s|<server>.<tailnet>.ts.net|$NODE|g" linux-server/cockpit/cockpit.conf.example \
       | sudo install -o root -g root -m 644 /dev/stdin /etc/cockpit/cockpit.conf
     sudo grep -v '^#' /etc/cockpit/cockpit.conf | grep -c '[<>]'   # expected: 0
     sudo test -f <backup-dir>/cockpit.conf && sudo diff <backup-dir>/cockpit.conf /etc/cockpit/cockpit.conf
     # carry over any other old [WebService] setting from that diff by hand
     sudo systemctl restart cockpit
     docker rm -f cockpit-ts                                        # DESTRUCTIVE (container only)
     ```

   - `tailscale-web`, as the operator user, in `<repo>`:

     ```sh
     (umask 022; printf 'TAILSCALE_WEB_ORIGIN=https://%s\n' "$NODE" > ~/.config/tailscale-web.env)
     install -m 644 linux-server/tailscale-web.service ~/.config/systemd/user/tailscale-web.service
     systemctl --user daemon-reload && systemctl --user enable tailscale-web && systemctl --user restart tailscale-web
     ss -ltnH 'sport = :8088'      # expected: 127.0.0.1:8088 only
     docker rm -f tailscale-web-ts # DESTRUCTIVE (container only)
     ```

4. **Stateless apps**, one stack step each: `openspeedtest`, `watchtower`,
   `speedtest-tracker` (`.env` first), `atvloadly`, `filebrowser`,
   `portainer`.
5. **Stateful or protocol-bearing apps**:
   - `qbittorrent`: qBittorrent rewrites its config on exit, so stop it
     before editing:

     ```sh
     cd <repo>/linux-server/qbittorrent
     docker compose stop qbittorrent
     sudo cp -a config/qBittorrent/qBittorrent.conf <backup-dir>/
     sudo grep -n '^WebUI\\Address=' config/qBittorrent/qBittorrent.conf
     sudo sed -i 's/^WebUI\\Address=.*/WebUI\\Address=*/' config/qBittorrent/qBittorrent.conf
     ```

     If the key is absent, the default is `*`. Then run a stack step
     (`qbittorrent-ts`).
   - `syncthing`: a stack step (`syncthing-ts`). Peers reconnect on `:22000`.
   - `adguard`: a stack step (`adguard-ts`). DNS keeps serving, because
     `adguardhome` is not recreated. `dig @<server-ip> example.com +short`
     answers. Right after, on the Pi, set `ORIGIN_URL` in
     `linux-pi/adguardhome-sync/.env` and run
     `docker compose up -d` in `linux-pi/adguardhome-sync`. Expected: its log
     shows a successful sync on the next run
     (`docker logs --since 10m adguardhome-sync`).
   - `uptime-kuma`: a stack step (`uptime-kuma-ts`).
6. **Right after uptime-kuma**: `pushloop linux-server/adguard/.env`,
   `pushloop linux-server/backup/.env`, `pushloop linux-server/forgejo/.env`
   (§2). On the Pi, set `KUMA_PUSH_URL` in `linux-pi/backup/.env` to the §2
   value, keeping its token. These scripts read their `.env` on each run, so
   nothing needs a restart. Check:
   `sudo systemctl start forgejo-runner-status.service dns-watchdog.service`
   exits 0. The scripts don't log push failures, so the proof is HUMAN: the
   forgejo-runner and DNS-watchdog push monitors turn green in the Kuma UI
   within a minute. The backup monitor turns green after its next nightly
   run.
7. **Gate before the Services**: every §4 probe for steps 1–6 passes, and
   `docker ps --format '{{.Names}}' | grep -- '-ts$'` lists only `ntfy-ts`,
   `immich-ts` and `forgejo-ts`.
8. **The three Services, one at a time, in this order: ntfy, immich,
   forgejo** (D3). Each has a short planned outage; tell the user before
   starting.
9. For each `svc:X`, with sidecar `X-ts` (forgejo also has `tcp:22`):
   1. Run a stack step in `linux-server/X`. **DESTRUCTIVE**: the old node goes
      offline and the outage starts.
   2. HUMAN, Machines page: delete the old `X` machine (the offline
      `tag:container` node named `X`). **DESTRUCTIVE**: this one cannot be
      undone by `ts-state/`.
   3. HUMAN, Services page: **Define a Service** named `X` with endpoint
      `tcp:443` (forgejo: `tcp:443` and `tcp:22`). In Access controls, add:

      ```json
      "autoApprovers": { "services": { "svc:X": ["tag:server"] } },
      "grants": [ { "src": ["autogroup:member"], "dst": ["svc:X"], "ip": ["tcp:443"] } ]
      ```

      For forgejo, `"ip": ["tcp:443", "tcp:22"]`. Merge the entries into the
      existing `autoApprovers` and `grants`, keeping the rules already there.
   4. `scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services svc:X --dry-run`.
      Expected: `==> Would run` has `set-raw` and `tailscale serve advertise svc:X`,
      and the diff adds only `Services["svc:X"]`. Then the same without
      `--dry-run`: `applied …`.
   5. HUMAN: on the Services page, approve the host if `autoApprovers` did
      not. If the Service shows as misconfigured, use the fallback from design §3.5:
      `tailscale serve --service=svc:X --https=443 http://127.0.0.1:<port>`
      (forgejo also `--tcp=22 tcp://127.0.0.1:2222`), and log the deviation.
   6. Run the §4 probe for `X` from another tailnet device. The outage ends.
   - After **ntfy**: set `NTFY_URL` to loopback in `adguard`, `backup`,
     `dragonwilds`, `ups` and `forgejo` `.env`. Then
     `sudo bash linux-server/ups/setup.sh --dry-run`, then
     `sudo bash linux-server/ups/setup.sh`, so upsmon's
     `/etc/nut/ups-notify.env` picks it up. Publish a test:
     `curl -sS -d test http://127.0.0.1:8103/<a-test-topic>`, which should
     arrive on the phone (HUMAN).
   - After **forgejo**: remove `FORGEJO_RUNNER_API_URL` from
     `forgejo/.env`. The default is loopback.
10. **Reboot the server.** `sudo systemctl reboot`. After it is up: NPM is
    running bound to the LAN IP (`docker ps --filter name=nginx-proxy-manager`,
    and `ss` as in step 1), and
    `scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json` prints
    `up to date`. Run the full §4 probe again.

### 3. Pi: host node and cutover (design §4.4)

Run on the Pi, in its `<repo>`.

1. **Pre-flight.** Record `git rev-parse HEAD` as the Pi's
   `<pre-migration-commit>`. Then `ss -ltnH` for 80, 631, 3001 and 8765 shows
   the host services, and `ss -ltnH 'sport = :8631'` prints nothing. Check
   `tailscale version` (floor 1.102.3) and `systemctl cat pi-backup.service`.
2. **Host node.** If `tailscale status --json` shows `BackendState: Running`
   for the Pi host (not a container), HUMAN: apply `tag:pi` on the Machines
   page and disable key expiry, as in §0.1 step 4. If there is no host
   tailscaled, install it with the official Linux installer
   (https://tailscale.com/kb/1031/install-linux), then run
   `sudo tailscale up --advertise-tags=tag:pi --accept-dns=false`. HUMAN: open
   the printed login URL. Either way, then run
   `sudo tailscale set --operator=$USER`, and install `jq`. Confirm:
   `tailscale status --json | jq -r '.Self.Tags[]'` prints `tag:pi`, and SSH to
   the Pi still works.
3. **Backups.** Use a new `<backup-dir>` on the Pi:

   ```sh
   sudo bash -euo pipefail -c 'B="$1"; R="$2"
   mkdir -m 700 -- "$B"
   systemctl start pi-backup.service
   cd "$R/linux-pi"
   tar -czf "$B/ts-state-pi.tgz" -- */ts-state
   out=$(tailscale serve status --json)
   [[ -n "$out" ]] || out="{}"
   jq -e "if . == null then {} else . end | objects" <<< "$out" > "$B/serve-before.json"
   if [[ "$(jq length "$B/serve-before.json")" == 0 ]]; then printf "empty\n"; else printf "config\n"; fi > "$B/serve-before.state"
   rc=0; tailscale serve get-config --all "$B/serve-services-before.json" || rc=$?
   printf "%s\n" "$rc" > "$B/serve-services-before.rc"
   mkdir -m 700 -- "$B/env"; cd "$R"; cp -a --parents linux-pi/*/.env "$B/env/"
   : > "$B/capture-complete"' _ <backup-dir> <repo>

   sudo bash -euo pipefail -c 'B="$1"
   [[ "$(stat -c "%a %U" "$B")" == "700 root" ]]
   [[ -f "$B/capture-complete" ]]
   [[ "$(systemctl show -p Result --value pi-backup.service)" == success ]]
   [[ "$(tar -tzf "$B/ts-state-pi.tgz")" == */ts-state/* ]]
   n=$(jq -e "objects | length" "$B/serve-before.json")
   state=$(<"$B/serve-before.state")
   [[ ( "$state" == empty && "$n" == 0 ) || ( "$state" == config && "$n" != 0 ) ]]
   printf "backup-ok\n"' _ <backup-dir>
   ```

   Do not continue unless it prints `backup-ok`. The `env/` copy already
   holds the §2 edits to adguardhome-sync and backup. The pre-server values
   are in `<pi-env-backup-dir>`.
4. **Checkout and serve.**
   `git checkout feat/86-one-node-per-host` at the approved head. Create
   `linux-pi/tailscale-serve/.env` with the command from §1.2 step 2 (in
   `linux-pi/tailscale-serve`). Then:

   ```sh
   scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json --dry-run
   scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json
   scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json   # expected: up to date
   ```

   The dry-run's `==> Would run` lists only `set-raw`, and the diff adds
   `TCP` 443, 8443 and 8449. Homepage, motioneye and adguard answer at once.
   `:8449` gives 502 until step 5.
5. **Stacks**, each with `docker compose config -q && docker compose up -d --remove-orphans`:
   - `homepage`: `.env` — set `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` to the Pi
     node's name and `HOMEPAGE_VAR_MAIN_HOMEPAGE_DOMAIN` to the server node's
     name. Remove `HOMEPAGE_VAR_ADGUARD_PI_DOMAIN`,
     `HOMEPAGE_VAR_MOTIONEYE_DOMAIN` and `HOMEPAGE_VAR_CUPS_DOMAIN`. This
     removes `homepage-pi-ts`.
   - `adguard`: removes `adguard-pi-ts`. `adguardhome` is unchanged, so DNS on
     `:53` is not touched: `dig @<pi-lan-ip> example.com +short` answers.
   - `cups`: starts `cups-proxy` on `127.0.0.1:8631` and removes `cups-ts`.
   - `docker rm -f motioneye-ts` (its stack is deleted on the branch;
     **DESTRUCTIVE**, container only).
   - The old cups bridge network: `docker network ls --filter name=cups` shows
     the cups project's `default` network. If no container uses it
     (`docker network inspect -f '{{len .Containers}}' <net>` prints `0`),
     run `docker network rm <net>`.
   - CUPS policy: in `linux-pi/cups/.env`, delete `CUPS_SIDECAR_SUBNET`, and
     drop the old sidecar name from `CUPS_SERVER_ALIAS`, so only LAN names
     remain. `chmod 600 .env`. Then in `linux-pi/cups`:
     `bash test-setup.sh`, `bash setup.sh --dry-run` and
     `sudo bash setup.sh --prepare-review`. HUMAN: from a trusted terminal,
     not an LLM-controlled one, review
     `/var/lib/cups-policy-review/pending.diff` and `candidate.conf` (see
     `linux-pi/cups/README.md`). Then run
     `sudo bash setup.sh --apply-reviewed <source-sha256> <candidate-sha256>`
     with the hashes `--prepare-review` printed. Its
     `cupsd.conf.bak.<timestamp>` is this step's rollback.
   - Check the shim without the tailnet:
     `curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: $NODE:8449" http://127.0.0.1:8631/`
     prints `200`. The same request to `http://127.0.0.1:631/` prints `400`.
6. Run `getent hosts <server>.<tailnet>.ts.net` again on the Pi. It resolves.
7. **Neighbours.** `adguardhome-sync` and `backup` hold the §2 values. The
   next sync run is OK, and the next `pi-backup` push turns the Kuma monitor
   green (`sudo systemctl start pi-backup.service` to force one). Then on the
   **server**, set `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` in
   `linux-server/homepage/.env` to the Pi node's name, and run
   `docker compose up -d` in `linux-server/homepage`.
8. **Reboot the Pi.** Then `scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json`
   prints `up to date`, `dig @<pi-lan-ip>` answers, and the Pi probes in §4
   pass.

### 4. Verification

**Host checks**, on the host, after each stack and again after each reboot:

```sh
ss -ltnH 'sport = :<backend-port>'                        # only 127.0.0.1:<port> (or the host service named in design §2.2/§2.3)
docker ps -a --format '{{.Names}}' | grep -- '-ts$'       # only stacks not yet cut over
tailscale serve status --json | jq -r '.TCP | keys | join(",")'  # server: 443,8443,...,8448; Pi: 443,8443,8449 (plus anything preserved from §1 step 2)
scripts/ts-serve-apply.sh <host-dir>/tailscale-serve/serve.json --services <none|svc:a,svc:b> --dry-run   # "up to date"; pick the Services already applied
```

**Front-door probe**, from a tailnet device other than the host (D10). Use
the Pi for the server and the server for the Pi, if their MagicDNS
resolves (§1 step 6). Otherwise ask the user to run it on a laptop (HUMAN).
Set `S`, `P` and `T` to the server node name, the Pi node name and the
MagicDNS suffix, then run only the lines for stacks already cut over:

```sh
probe() { while read -r want url; do
  got=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)
  [[ ",$want," == *",$got,"* ]] && r=ok || r=FAIL
  printf '%-4s %-3s want=%-11s %s\n' "$r" "$got" "$want" "$(sed -E 's#^https://[^/:]+#https://<host>#' <<< "$url")"
done; }
probe <<EOF
200 https://$S/
200 https://$S/glances/api/4/status
200 https://$S/openspeedtest/
401,403 https://$S/qbittorrent/api/v2/app/version
200 https://$S/syncthing/rest/noauth/health
401 https://$S/watchtower/v1/metrics
200 https://$S/cockpit-ui/
200 https://$S/filebrowser/
200 https://$S/portainer/api/system/status
200 https://$S/tailscale-web/
401,403 https://$S:8443/control/status
200,302 https://$S:8444/
200 https://$S:8445/admin/login
200 https://$S:8446/
200 https://$S:8447/
200 https://$S:8448/
200 https://ntfy.$T/v1/health
200 https://immich.$T/api/server/ping
200 https://forgejo.$T/api/v1/version
200 https://$P/
200 https://$P/motioneye/
401,403 https://$P:8443/control/status
200 https://$P:8449/
EOF
```

Expected: every line `ok`. The output masks host names. A redirect must stay
on the same origin and under its mount:
`curl -sS -o /dev/null -w '%{redirect_url}\n' <url>`.

**Functional checks.** These are HUMAN (a browser or phone), unless the agent
has the credentials in a `.env` it may use without printing them:

| Service | Check | Note |
|---|---|---|
| homepage | Widgets load on both hosts | Widgets use loopback |
| qbittorrent, filebrowser, portainer, adguard, uptime-kuma, NPM, cockpit | Login works; the same API call then returns 200 | Cockpit terminal and the portainer console use websockets (UNVERIFIED under a prefix) |
| tailscale-web | The manage flow works | UNVERIFIED |
| openspeedtest | A browser run with upload | Body limit UNVERIFIED |
| syncthing | GUI asks for the password; peers connected | — |
| ntfy | A test message reaches the phone | — |
| immich | The mobile app syncs with no setting change | — |
| forgejo | `git ls-remote` over HTTPS and SSH from an existing clone; the macOS runner shows online | SSH goes through `svc:forgejo` `tcp:22` |
| Pi cups | `/printers/` lists printers; `/admin/` asks for auth | — |
| DNS | `dig @<server-ip>` and `dig @<pi-lan-ip>` answer | — |

**#86 acceptance**, after both hosts:
- `docker ps -a --format '{{.Names}}' | grep -c -- '-ts$'` prints `0` on both
  hosts.
- `tailscale serve status --json` matches each template (the apply script
  prints `up to date`).
- The old nodes are offline in the admin console. They are deleted in §6,
  after the soak.

### 5. Rollback (design §4.6)

**5.1 One stack, while its old node still exists** (every stack except a
Service whose node was deleted):

```sh
cd <repo>
git checkout <pre-migration-commit> -- <host-dir>/<stack>
sudo cp -a <backup-dir>/env/<host-dir>/<stack>/.env <host-dir>/<stack>/.env
cd <host-dir>/<stack> && docker compose up -d --remove-orphans
```

The sidecar starts from its `ts-state/` and gets its old name back. The serve
handler can stay; it returns 502 until the stack is migrated again. For
`cockpit`, also restore the conf: `sudo install -m 644 <backup-dir>/cockpit.conf /etc/cockpit/cockpit.conf`
(or `sudo rm /etc/cockpit/cockpit.conf` if `cockpit.conf.absent` exists), then
restart cockpit. For `tailscale-web`, run
`sudo install -o "$USER" -m 644 <backup-dir>/tailscale-web.service ~/.config/systemd/user/`,
then `systemctl --user daemon-reload && systemctl --user restart tailscale-web`.
For `qbittorrent`, stop it and restore `qBittorrent.conf` from `<backup-dir>`
first. Log the dirty paths; `git checkout HEAD -- <path>` undoes them before
the stack is retried.

**5.2 One Service, after its node was deleted:**
`tailscale serve drain svc:X`, then `tailscale serve clear svc:X`. HUMAN:
delete the Service on the Services page, so the name is free again. Then empty
that stack's `ts-state/` (`sudo find <repo>/linux-server/X/ts-state -mindepth 1 -delete`;
its node key belonged to the deleted node), and do 5.1. The sidecar
re-authenticates with `TS_AUTHKEY`, which is why the OAuth client keeps its
Auth Keys scope until §6.

**5.3 Whole host:**

Run in this order: first 5.2 for every Service already cut over (while its
Service config still exists), then restore Serve from the backup in a root
process. The restore is chosen by `serve-before.state`, never by the size of
a file:

```sh
sudo bash -euo pipefail -c 'B="$1"
[[ -f "$B/capture-complete" ]]
case "$(<"$B/serve-before.state")" in
  empty)  tailscale serve reset ;;
  config) tailscale serve set-raw < "$B/serve-before.json" ;;
  *)      exit 1 ;;
esac' _ <backup-dir>
```

Then `git -C <repo> checkout <pre-migration-commit>`, and restore every `.env` from
`<backup-dir>/env/`. For a server rollback, also restore the Pi's
`adguardhome-sync` and `backup` `.env` from `<pi-env-backup-dir>`, on the Pi.
Restore `cockpit.conf`, the tailscale-web unit and `qBittorrent.conf` as in
5.1, and bring up every stack with `docker compose up -d --remove-orphans`.
If an `.env` copy is missing, use the restic snapshot from §1.1
(`linux-server/backup/README.md`, "restore"). The host tags can stay. On the
Pi, the CUPS policy rolls back from its `cupsd.conf.bak.<timestamp>`.

### 6. After the soak (7 days, both hosts verified; design §4.7)

Do not start this early: the soak is what keeps rollback cheap.

- HUMAN, Machines page: delete every remaining old sidecar node on both
  hosts (the offline `tag:container` nodes). **DESTRUCTIVE.**
- On each host: `sudo find <repo>/<host-dir> -mindepth 2 -maxdepth 2 -type d -name ts-state`
  lists them. Delete each, remove `TS_AUTHKEY` from every `.env`, and run
  `sudo rm <backup-dir>/ts-state-*.tgz`. **DESTRUCTIVE.**
- HUMAN: remove the Auth Keys scope from the OAuth client the sidecars used.
  Keep its read scope, because tailscale-proxy still uses it. Revoke any
  reusable auth key made for sidecars (Settings → Keys).
- HUMAN: remove `tag:container` from `tagOwners` and from any rule.
- Repo follow-up (a separate PR): drop the `ts-state/` lines from
  `.gitignore`.

### 7. Client updates (HUMAN; design §4.8)

- Forgejo remotes, the macOS runner, ntfy phone subscriptions and the Immich
  mobile app: no change, because the Services keep the old names. If SSH warns
  that the host IP changed, run `ssh-keygen -R <old-ip>`; the host key is the
  same.
- Bookmarks and password-manager entries: every other URL moves from
  `https://<svc>.<tailnet>.ts.net` to its front door (`linux-server/HTTPS.md`
  tables). Path-mounted apps now share one host name in the password manager.
- Cockpit on the LAN: `https://<server-ip>:9090/cockpit-ui/`.
- Uptime Kuma: edit each HTTP monitor to its new URL in the UI, per
  `linux-server/uptime-kuma/monitors.md`. A monitor that fails while the URL
  works from another device moves to its loopback fallback.
- Syncthing peers that dial `tcp://syncthing.<tailnet>.ts.net:22000`: change
  the address to the server node's name.
- Game host homepage (`linux-game-server/homepage/.env` on that host, which is
  not in this PR): set `HOMEPAGE_VAR_MAIN_HOMEPAGE_DOMAIN` to the server node's
  name and `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` to the Pi node's name. Set
  `HOMEPAGE_VAR_UPTIMEKUMA_DOMAIN` to `<server>.<tailnet>.ts.net:8444`,
  `HOMEPAGE_VAR_ADGUARD_DOMAIN` to `<server>.<tailnet>.ts.net:8443` and
  `HOMEPAGE_VAR_SYNCTHING_DOMAIN` to `<server>.<tailnet>.ts.net/syncthing`.
  Then run `docker compose up -d` in its homepage dir. The ntfy, forgejo and
  immich values don't change.
- Off-repo shell rc files or scripts that `curl` ntfy or another `*.ts.net`
  URL.

### What to report back

Report each step id with pass, fail or skipped, every deviation and the
UNVERIFIED items from design §6 that were settled, plus anything left
for the user. Do not include `.env` values, names or IPs. Once both hosts have
passed §4, the #86 acceptance boxes can be ticked, except "old nodes gone",
which waits for §6.

Completed rollout history lives in [CHANGELOG.md](CHANGELOG.md), and remaining
work lives in [TODO.md](TODO.md).
