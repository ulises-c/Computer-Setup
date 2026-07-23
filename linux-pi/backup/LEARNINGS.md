# Pi backup setup — key learnings

Lessons from wiring up restic-over-SFTP from a Raspberry Pi to a main
server's DAS over the tailnet. Save these before they evaporate.

## Linux nologin shells output a message

`/usr/sbin/nologin` on Debian prints "This account is currently not available."
to stderr before exiting. This corrupts the SFTP protocol stream, and restic
reports "packet too long".

**Fix:** Use `/bin/false` instead. It exits silently with status 1, no output.

```
sudo usermod -s /bin/false <backup-user>
```

## ForceCommand internal-sftp is required for shell-less SFTP

When a user has `/bin/false` as their login shell, the SSH server can't launch a
shell — but SFTP still works if you add a Match block to sshd_config:

```
Match User <backup-user>
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
```

`internal-sftp` runs the SFTP subsystem in-process (no shell needed). This also
locks the account to SFTP-only — no shell commands, no port forwarding.

## Restic's `sftp:` backend uses the system SSH command

Restic shells out to `ssh` for SFTP repositories. It reads the active user's SSH
configuration, identities, and known-host entries. The systemd unit sets
`HOME=/root`, so its configuration belongs under `/root/.ssh/`.

```sshconfig
Host pi-backup-target
    HostName <server-ip>
    User <backup-user>
    IdentityFile /root/.ssh/backup
```

Repository URLs can then use `sftp:pi-backup-target:/path/to/repository`.

## The `ssh:` backend doesn't work with ForceCommand

Restic's `ssh:` backend executes `restic serve ssh` on the remote side. When
`ForceCommand internal-sftp` is set, the server ignores that and runs SFTP
instead — protocol mismatch. Stick with the `sftp:` backend for restricted
users.

## `ssh-copy-id` fails with nologin/false shells

`ssh-copy-id` needs to execute commands on the remote to install the key. With
`/bin/false` or `/usr/sbin/nologin`, it can't. Options:

1. Use `ssh-copy-id` before changing the shell (if setting up from scratch)
2. Manually append the public key to `authorized_keys`
3. Use `scp` to upload the key, then move it into place (requires a working shell)

In practice, the simplest path is: set up the user with a real shell first,
run `ssh-copy-id`, then change the shell to `/bin/false`.

## Backup key should have no passphrase

For automated backups (systemd timer), the SSH key must not have a passphrase.
Restic can't prompt for one in a non-interactive context.

```sh
ssh-keygen -t ed25519 -C "backup" -f ~/.ssh/backup -N ""
```

## Root needs its own SSH setup

Systemd timers typically run as root. If the backup script uses SSH/SFTP, root
needs:
- The private key (with `chmod 600`)
- An `IdentityFile` entry in `/root/.ssh/config`
- `~/.ssh/known_hosts` (host key acceptance)

Copy from the regular user:

```sh
sudo mkdir -p /root/.ssh
sudo cp ~/.ssh/backup /root/.ssh/backup
sudo cp ~/.ssh/backup.pub /root/.ssh/backup.pub
sudo chmod 700 /root/.ssh
sudo chmod 600 /root/.ssh/backup
sudo chmod 644 /root/.ssh/backup.pub
sudo cp ~/.ssh/known_hosts /root/.ssh/known_hosts
```

## Timer offset only reduces contention

If two machines back up to the same server, offset the timers. The Pi fires at
03:45 (15 min after the server's 03:30), but long prune/check runs can still
overlap. Choose the offset from observed server backup durations.
