# cups/ — Pi print server + HTTPS front door

The Pi hosts a USB printer through host CUPS on port 631. Family devices print
directly over the home LAN/WLAN, while the `cups-ts` sidecar provides the
operator's remote HTTPS route over Tailscale.

## Access policy

`setup.sh` renders three exact access blocks in `/etc/cups/cupsd.conf`:

- `<Location />` permits `localhost`, the pinned sidecar subnet, and the home
  LAN/WLAN subnet. This supports family printing and the HTTPS sidecar.
- `<Location /admin>` and every descendant admin location permit only
  `localhost` and the sidecar subnet. Each is normalized to `AuthType Default`
  with `Require user @SYSTEM`.
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
  spaces, including the exact Tailscale name and the LAN/Bonjour names.
- `CUPS_SIDECAR_SUBNET`: the bridge CIDR pinned in `docker-compose.yml`. The
  setup script requires the exact pin.
- `CUPS_LAN_SUBNET`: the canonical private CIDR used by family LAN/WLAN
  clients. It is allowed for printing but not administration.

Set `.env` to mode `0600`; the installer refuses to source a more broadly
readable file because it also contains the sidecar credential.

If upgrading from the old policy, replace `CUPS_ALLOW_FROM` with the two subnet
variables above. No private hostname, tailnet name, or LAN address belongs in a
tracked file or LLM transcript.

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

Confirm that the print block contains localhost, the exact pinned sidecar
subnet, and the exact family LAN/WLAN subnet; every admin block must contain
only localhost and the sidecar subnet plus the exact system-user authentication
policy. Confirm that no broad access rule survives.

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

## Live verification

After applying, verify without printing private values into an LLM transcript:

1. `cups.service` is enabled and active, and `cups.socket` is disabled.
2. A family device on LAN/WLAN can discover and print a test page.
3. An HTTP request from the `cups-ts` container to the host CUPS service works.
4. The sidecar HTTPS endpoint works from an authorized tailnet client.
5. A client outside both approved networks is denied.
6. Administrative routes require authentication and are unavailable to an
   ordinary LAN-only client.

The sidecar bridge subnet is pinned in `docker-compose.yml`. If that pin ever
changes, update `.env`, prepare a new review, and apply the newly reviewed
candidate.

### macOS “Hold for authentication”

A Mac can display “Hold for authentication” when CUPS actually rejected the
request because of a Host-header or source-network mismatch. Correct the policy
and resume or recreate the job; macOS does not always retry it automatically.
