# Pi backups

Nightly [restic](https://restic.net) backup of the Pi's service configs to the
main server's DAS over SFTP. Encrypted, deduplicated, pruned, and reported to
ntfy + a homepage card. Mirrors the server's own backup architecture
(`linux-server/backup/`).

## What gets backed up

- **AdGuard** `conf/` — DNS settings, filter lists, rewrites, and restorable state
- **Homepage** `config/` — dashboard widgets, services, bookmarks
- **MotionEye** `/etc/motioneye/` — camera configs (recordings excluded — large/disposable)
- **CUPS** `/etc/cups/` — printer configs, PPD files
- Every service's gitignored **`.env`** (secrets needed to restore)

Excluded as disposable/regenerable: AdGuard query/statistics databases in `work/`,
MotionEye recordings, all `ts-state/`
(Tailscale node keys — re-auth with `TS_AUTHKEY` regenerates them), Docker
images/containers.

## How it works

The Pi pushes a restic repository over SFTP to the main server's DAS, with an
optional second copy for redundancy:

```
Pi (restic) ──SFTP──> Main Server (restic-pi user)
                      ├── /mnt/wd1tb/restic-pi     (primary)
                      └── /mnt/wd14tb/restic-pi-copy (second copy)
```

The second copy uses `restic copy --from-repo` (same pattern as the server's
own backup). It must be initialized explicitly. An unavailable or incomplete
second-repository operation is reported without failing the primary backup.

Restic's SFTP backend uses the system `ssh` command and honors SSH configuration.
Because the timer runs with `HOME=/root`, configure its host, identity, and known
host under `/root/.ssh/`.

The main script records a current-run marker; its EXIT trap writes detailed
failure status and removes staging. Systemd's `OnFailure` unit preserves and
acknowledges current detail, or replaces a missing, running, success, or stale
failure record before sending the single external ntfy/Kuma alert. The backup
unit has a two-hour runtime limit so a hung SFTP operation cannot block every
later timer run.

## Prerequisites

### 1. Install tools on the Pi

```sh
sudo apt install restic jq
```

### 2. Generate an SSH key and copy it to the server

Create an ed25519 key (no passphrase — it's for automated use):

```sh
ssh-keygen -t ed25519 -C "backup" -f ~/.ssh/backup -N ""
```

Copy the public key to the server. You can use the repo's `add_remote_host.sh`
or do it manually:

```sh
# Manual approach (more reliable with nologin users):
ssh-copy-id -i ~/.ssh/backup.pub restic-pi@<server-ip>
```

If `ssh-copy-id` fails (e.g. nologin shell), copy the key by hand:

```sh
# On the Pi:
cat ~/.ssh/backup.pub
# On the server, add the output to /home/restic-pi/.ssh/authorized_keys
```

### 3. Configure SSH for the root-run timer

Copy the key and known-host entry to root, then configure the repository host:

```sh
sudo mkdir -p /root/.ssh
sudo cp ~/.ssh/backup /root/.ssh/backup
sudo cp ~/.ssh/backup.pub /root/.ssh/backup.pub
sudo chmod 700 /root/.ssh
sudo chmod 600 /root/.ssh/backup
sudo chmod 644 /root/.ssh/backup.pub
sudo cp ~/.ssh/known_hosts /root/.ssh/known_hosts 2>/dev/null && sudo chmod 644 /root/.ssh/known_hosts || true
sudoedit /root/.ssh/config
```

```sshconfig
Host pi-backup-target
    HostName <server-ip>
    User restic-pi
    IdentityFile /root/.ssh/backup
```

Use `sftp:pi-backup-target:/mnt/...` for the repository URLs in `.env`.

### 4. Server-side setup

The main server needs a dedicated SFTP user for Pi backups. Create it manually
or pass this to the server's LLM agent:

```sh
# On the main server:
sudo useradd -m -s /bin/false restic-pi
sudo passwd restic-pi   # set a strong password (or use key-only auth)

# Create the restic repo dirs:
sudo mkdir -p /mnt/wd1tb/restic-pi /mnt/wd14tb/restic-pi-copy
sudo chown restic-pi:restic-pi /mnt/wd1tb/restic-pi /mnt/wd14tb/restic-pi-copy
```

The user **must** have:
- Shell: `/bin/false` (silent — `/usr/sbin/nologin` outputs a message that
  corrupts the SFTP protocol stream)
- SFTP access via `ForceCommand internal-sftp` in sshd_config:

```
Match User restic-pi
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
```

### 5. Configure

```sh
cd linux-pi/backup
cp .env.example .env
# set RESTIC_PASSWORD (and SAVE IT SECURELY), ntfy/Kuma URLs
chmod 600 .env
```

### 6. Initialize both repositories

```sh
set -a; source .env; set +a
restic init
restic -r "$SECOND_RESTIC_REPOSITORY" init --copy-chunker-params --from-repo "$RESTIC_REPOSITORY"
```

The script initializes the primary repository on first use. It never initializes the
optional second repository automatically because an unreachable SFTP target and an
uninitialized repository are not safely distinguishable.

### 7. Status card server

```sh
sudo docker compose up -d
```

### 8. Install + enable the timer

```sh
sudo bash setup.sh
```

`setup.sh` renders the service units with the current checkout path, installs them,
and enables the timer. Re-run it after moving the checkout.

### 9. Run + verify

```sh
sudo systemctl start pi-backup.service
journalctl -u pi-backup.service -f
restic snapshots          # confirm a snapshot landed
curl http://localhost:8099/backup-status.json  # check status card
```

## Restore

```sh
set -a; source .env; set +a
restic snapshots                                  # find the snapshot id
restic restore latest --target /tmp/restore       # or --include <path>
```

Then put state back per service:

- **AdGuard config:** stop the container, copy restored `conf/` into place,
  `docker compose up -d`
- **Homepage config:** stop the container, copy restored `config/` into place,
  `docker compose up -d`
- **MotionEye/CUPS configs:** copy restored files from `/etc/motioneye/` or
  `/etc/cups/`, restart the service (`sudo systemctl restart motioneye` / `cups`)
- **`.env` files:** copy restored `.env` files back, recreate affected containers

## Warnings

- **Losing `RESTIC_PASSWORD` = unrecoverable backups.** Keep it secure.
- The second copy is reported as incomplete if its target or an operation fails —
  don't rely on it as your only backup.
- Staged `.env` copies live under `/root/pi-backup-staging` with mode `0700` and
  are removed on normal exit. A forced kill can leave that root-only directory for
  the next run to replace.
- The script skips missing source paths, so it's safe to enable before every
  service is deployed; coverage grows automatically as data dirs appear.
