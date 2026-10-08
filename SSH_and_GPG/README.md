# SSH & GPG Scripts

Interactive shell scripts for setting up GPG keys, SSH keys, and Git commit signing.

---

## Scripts

### `create_gpg_key.sh`

Generates an Ed25519/Curve25519 GPG key pair and optionally attaches multiple email UIDs to it.

**What it does:**
- Prompts for a name, primary email, and key expiry (default: 2 years)
- Optionally collects additional emails and adds each as a separate UID on the same key
- Exports the armored public key to stdout for pasting into GitHub/GitLab/etc.
- Optionally configures `git` globally to sign commits with the new key
- Verifies the key can sign before exiting

**Usage:**
```bash
bash create_gpg_key.sh
# or pre-fill inputs via env vars:
NAME="Jane Doe" EMAIL="jane@example.com" EXPIRY="1y" bash create_gpg_key.sh
```

**Add an email to an existing key** (for example a personal email next to a work one, so one key
signs for both identities):
```bash
bash create_gpg_key.sh --add-email <key-id>
```
It lists the key's current emails, prompts for new ones (skipping any the key already has), and
prints the updated public key. Re-upload that key to every Git host that has the old one: hosts
check each commit's email against the emails on the key. Once a key is published, its emails are
public and can be revoked but never removed.

---

### `create_ssh_key.sh`

Creates an Ed25519 SSH key for authenticating to a Git host (GitHub, GitLab, Bitbucket, Hugging Face, self-hosted, or custom).

**What it does:**
- Prompts for an email (used as the key comment), Git host, key filename, and optional passphrase
- For passphrase-protected keys: prompts for an agent timeout in minutes (default `15`) — `ssh-agent` keeps the key unlocked that long after each `ssh-add`, so you aren't re-typing the passphrase on every push; `0` disables caching entirely (passphrase asked on every use). The `Host` block gets a matching `AddKeysToAgent <N>m` (needs OpenSSH 8.7+) so keys re-added on first use expire too
- Generates the key in `~/.ssh/` (skips generation if the key already exists, with an overwrite prompt)
- Adds the key to `ssh-agent` and updates `~/.ssh/config` with a `Host` block (idempotent)
- For self-hosted servers: prompts for an SSH port (default `22`) and writes an alias with `HostName`, `Port`, and `User git` so you can clone as `git clone <alias>:<user>/<repo>.git`
- Prints the public key for pasting into the Git host's settings
- Tests the SSH connection after you confirm the key has been added

**Usage:**
```bash
bash create_ssh_key.sh
# or pre-fill inputs via env vars:
EMAIL="jane@example.com" GIT_HOST="github.com" KEY_NAME="github" bash create_ssh_key.sh
# Passphrase-protected key, cached in ssh-agent for 30 minutes:
EMAIL="jane@example.com" GIT_HOST="github.com" KEY_NAME="github" SSH_PASSPHRASE="..." AGENT_TIMEOUT=30 bash create_ssh_key.sh
# Self-hosted Git server:
EMAIL="jane@example.com" IS_SELF_HOSTED=true GIT_HOSTNAME="hostname.ts.net" GIT_HOST="gitserver" GIT_SSH_PORT=22 bash create_ssh_key.sh
```

---

### `add_remote_host.sh`

Creates an Ed25519 SSH key for a remote machine (e.g. a home server or Tailscale node), copies the public key to that machine, and wires up `~/.ssh/config`. An alias can have several addresses (IPs, `<hostname>.local`, a second interface), so a machine that moves to another switch, VLAN or DHCP lease is still reachable.

**What it does:**
- Prompts for a host alias, one or more remote addresses, username, port, key filename, and optional passphrase
- Optionally accepts the remote account password (uses `sshpass` when available to avoid interactive prompts; install with `brew install sshpass`)
- Copies the public key to the first reachable address using BatchMode → sshpass → interactive fallback, then verifies the key actually landed
- Writes a managed `# BEGIN/END add_remote_host.sh: <alias>` block in `~/.ssh/config`, in place of the alias's previous block (idempotent; also migrates a block from an older version of the script), and checks with `ssh -G` that no earlier entry such as `Host *` overrides it
- Pins the host key to the alias (`HostKeyAlias`). Keys already trusted in `known_hosts` for the first known address are pinned to the alias, and every other known address must share one of them
- Tests the connection through the alias before exiting

It stops without changing anything when:
- `known_hosts` already trusts different keys for two of the alias's addresses (they may be different machines)
- an existing block also sets options the rewrite would drop (`ProxyJump`, a second `User`/`IdentityFile`, …), or has a `HostName`/`Port` that is not a plain address or number
- the markers for the alias are unpaired or repeated
- several addresses are given but `nc` is not installed

**Multiple addresses:** addresses are tried in order. Each one except the last gets a `Match … exec "nc -z -w 1 <address> <port>"` block that is used when the address accepts a TCP connection. The last one is the plain `Host` fallback. Each unreachable address costs about 1 s per connection, and the probes run only for that alias. Because the host key is checked under the alias, a new address for the same machine does not trigger a warning, while a different machine at a stale address still fails with `REMOTE HOST IDENTIFICATION HAS CHANGED`. `.local` names need mDNS (built in on macOS, `avahi` + `nss-mdns` on Linux) and usually do not resolve across subnets, so list them alongside an IP.

**Usage:**
```bash
bash add_remote_host.sh
# or pre-fill inputs via env vars (REMOTE_HOST still works for a single address):
HOST_ALIAS="homepc" REMOTE_HOSTS="homepc.local <server-ip>" REMOTE_USER="<username>" PORT="22" bash add_remote_host.sh

# add addresses to an existing alias (new ones are tried first; also migrates an old-style block):
bash add_remote_host.sh --add-address homepc <wifi-ip>
```

Re-running for an existing alias keeps the addresses it already has, after the ones you pass.

---

### `git-add-ssh-signer.sh`

Registers an SSH public key as a trusted Git commit signer and optionally configures a specific repo to sign with it.

**What it does:**
- Appends `<email> <public-key>` to `~/.config/git/allowed_signers` (idempotent)
- Sets `gpg.format = ssh` and `gpg.ssh.allowedSignersFile` globally so `git verify-commit` works
- With `--local`: also sets `user.email`, `user.signingkey`, and `commit.gpgsign = true` in the current repo

**Usage:**
```bash
# Global trust only (lets you verify commits from this key anywhere):
bash git-add-ssh-signer.sh jane@example.com ~/.ssh/github.pub

# Global trust + activate signing in the current repo:
bash git-add-ssh-signer.sh jane@example.com ~/.ssh/github.pub --local
```
