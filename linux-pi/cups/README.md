# cups/ — Pi print server + HTTPS front door

The Pi hosts a USB printer through host CUPS on port 631. Family devices print
directly over the home LAN/WLAN. The operator's remote route is
`https://<pi-hostname>.<tailnet>.ts.net:8449`, published by host tailscale
serve (`../tailscale-serve/serve.json`) through a small loopback nginx shim:

```
tailnet :8449 -> serve -> 127.0.0.1:8631 (cups-proxy) -> 127.0.0.1:631 (cupsd)
```

## Why the shim

cupsd checks the `Host` header. On a loopback connection it accepts only
`localhost`, `localhost.`, `127.0.0.1` or `[::1]` and ignores `ServerAlias`
([`valid_host()` in scheduler/client.c](https://github.com/OpenPrinting/cups/blob/v2.4.2/scheduler/client.c)).
Serve always connects from loopback and passes the client's `Host`
(`<pi-hostname>.<tailnet>.ts.net:8449`) through unchanged, so cupsd answers
`400 Bad Request` to every request that comes straight from serve. The
`cups-proxy` container (`docker-compose.yml`, host network, `nginx.conf`)
listens on `127.0.0.1:8631`, sets `Host: localhost`, and forwards to `:631`.
CUPS then sees a local request, so the `localhost` rules below apply and the
admin pages still require a system user's password.

## Access policy

`setup.sh` renders three exact access blocks in `/etc/cups/cupsd.conf`:

- `<Location />` permits `localhost` and the home LAN/WLAN subnet. This
  supports family printing and the tailnet front door (through the shim).
- `<Location /admin>` and every descendant admin location permit only
  `localhost`. Each is normalized to `AuthType Default` with
  `Require user @SYSTEM`.
- Sources outside those ranges are denied. The renderer rejects wildcard
  aliases, open networks, non-private networks, non-canonical CIDRs, malformed
  hostnames, duplicate aliases, and control-character injection.

The renderer replaces all TCP `Listen` and `Port` directives with exactly one
`Port 631`, while preserving Unix-socket listeners such as
`Listen /run/cups/cups.sock`. It also replaces every active `ServerAlias` with
the explicit hostnames from `.env`. `ServerAlias *`, `Allow all`, and
internet-wide CIDRs are never accepted.

## Private configuration

Copy `.env.example` to the gitignored `.env` and set:

- `CUPS_SERVER_ALIAS`: lowercase canonical hostnames separated by single
  spaces: the LAN/Bonjour names. The tailnet name is not needed, because the
  shim sends `Host: localhost`.
- `CUPS_LAN_SUBNET`: the canonical private CIDR used by family LAN/WLAN
  clients. It is allowed for printing but not administration.

Set `.env` to mode `0600`; the installer refuses to source a more broadly
readable file.

If upgrading from the sidecar policy, delete `CUPS_SIDECAR_SUBNET` and
`TS_AUTHKEY` from `.env` (`setup.sh` ignores them) and drop the old sidecar
name from `CUPS_SERVER_ALIAS`. No private hostname, tailnet name, or LAN
address belongs in a tracked file or LLM transcript.

## Reviewed deployment

The ordinary dry-run is intentionally redacted:

```bash
cd linux-pi/cups
chmod 600 .env
bash setup.sh --dry-run
```

It renders and runs `cupsd -t`, then reports only whether a change is pending.
It never prints the rendered configuration, aliases, or CIDRs.

Prepare the exact candidate and diff as root-only artifacts:

```bash
sudo bash setup.sh --prepare-review
```

The command prints source and candidate hashes but no private values. From a
separate trusted human terminal—not an LLM-controlled terminal—inspect:

```bash
sudo less /var/lib/cups-policy-review/pending.diff
sudo less /var/lib/cups-policy-review/candidate.conf
```

Confirm that the print block contains localhost and the exact family LAN/WLAN
subnet; every admin block must contain only localhost plus the exact
system-user authentication policy. Confirm that no broad access rule survives.

Apply exactly what was reviewed by passing both hashes printed by the prepare
step:

```bash
sudo bash setup.sh --apply-reviewed <source-sha256> <candidate-sha256>
```

The apply step refuses stale or altered artifacts, validates the candidate
again, backs up the current configuration, disables `cups.socket`, enables and
restarts `cups.service`, and probes CUPS locally with a valid Host header. A
socket, restart, or probe failure restores the previous configuration. Review
artifacts use root ownership with directory mode `0700` and file mode `0600`;
they are removed after a successful apply.

Then start the shim:

```bash
docker compose up -d
```

## Live verification

After applying, verify without printing private values into an LLM transcript:

1. `cups.service` is enabled and active, and `cups.socket` is disabled.
2. A family device on LAN/WLAN can discover and print a test page.
3. On the Pi, the shim answers and only on loopback:
   `curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: <pi-hostname>.<tailnet>.ts.net:8449' http://127.0.0.1:8631/`
   prints `200`, and `ss -ltnH 'sport = :8631'` shows only `127.0.0.1:8631`.
4. `https://<pi-hostname>.<tailnet>.ts.net:8449/` returns `200` from an
   authorized tailnet client, and `/admin/` returns `401` until a system
   user logs in.
5. A client outside both approved networks is denied.
6. Administrative routes require authentication and are unavailable to an
   ordinary LAN-only client.

### macOS “Hold for authentication”

A Mac can display “Hold for authentication” when CUPS actually rejected the
request because of a Host-header or source-network mismatch. Correct the policy
and resume or recreate the job; macOS does not always retry it automatically.
