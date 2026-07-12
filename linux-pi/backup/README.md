# Pi backups

Nightly [restic](https://restic.net) backup of the Pi's service configs to the
main server's DAS over SFTP. Encrypted, deduplicated, pruned, and reported to
ntfy + a homepage card. Mirrors the server's own backup architecture
(`linux-server/backup/`).

## What gets backed up

- **AdGuard** `conf/` + `work/` — DNS settings, filter lists, rewrites, runtime state
- **Homepage** `config/` — dashboard widgets, services, bookmarks
- **MotionEye** `/etc/motioneye/` — camera configs (recordings excluded — large/disposable)
- **CUPS** `/etc/cups/` — printer configs, PPD files
- Every service's gitignored **`.env`** (secrets needed to restore)

Excluded as disposable/regenerable: MotionEye recordings, all `ts-state/`
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
own backup). It's silently skipped if the SFTP connection to the second target
fails.

**Important:** Restic's built-in SSH client doesn't read `~/.ssh/config`. The
backup SSH key must be symlinked to `~/.ssh/id_ed25519` (the default path restic
looks for). The setup steps below handle this.

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

### 3. Symlink the key for restic

Restic's Go SSH client looks for `~/.ssh/id_ed25519` by default:

```sh
ln -sf ~/.ssh/backup ~/.ssh/id_ed25519
ln -sf ~/.ssh/backup.pub ~/.ssh/id_ed25519.pub
```

### 4. Copy key/config/known_hosts to root

The backup timer runs as **root**, so root needs the SSH setup:

```sh
sudo mkdir -p /root/.ssh
sudo cp ~/.ssh/backup /root/.ssh/backup
sudo cp ~/.ssh/backup.pub /root/.ssh/backup.pub
sudo ln -sf /root/.ssh/backup /root/.ssh/id_ed25519
sudo ln -sf /root/.ssh/backup.pub /root/.ssh/id_ed25519.pub
sudo chmod 700 /root/.ssh
sudo chmod 600 /root/.ssh/backup /root/.ssh/id_ed25519
sudo chmod 644 /root/.ssh/backup.pub /root/.ssh/id_ed25519.pub
sudo cp ~/.ssh/known_hosts /root/.ssh/known_hosts 2>/dev/null && sudo chmod 644 /root/.ssh/known_hosts || true
```

### 5. Server-side setup

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

### 6. Configure

```sh
cd linux-pi/backup
cp .env.example .env
# set RESTIC_PASSWORD (and SAVE IT SECURELY), ntfy/Kuma URLs
```

### 7. Initialize the repos (the script also does this on first run)

```sh
set -a; source .env; set +a
restic init
# Also init the second copy repo if using it
```

### 8. Status card server

```sh
sudo docker compose up -d
```

### 9. Install + enable the timer

```sh
sudo cp pi-backup.service pi-backup.timer pi-backup-failure.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pi-backup.timer
```

### 10. Dry run + verify

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
- The second copy is silently skipped if the target SFTP connection fails —
  don't rely on it as your only backup.
- The script skips missing source paths, so it's safe to enable before every
  service is deployed; coverage grows automatically as data dirs appear.
