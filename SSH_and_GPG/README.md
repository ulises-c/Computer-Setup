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

---

### `create_ssh_key.sh`

Creates an Ed25519 SSH key for authenticating to a Git host (GitHub, GitLab, Bitbucket, Hugging Face, self-hosted, or custom).

**What it does:**
- Prompts for an email (used as the key comment), Git host, key filename, and optional passphrase
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
# Self-hosted Git server:
EMAIL="jane@example.com" IS_SELF_HOSTED=true GIT_HOSTNAME="hostname.ts.net" GIT_HOST="gitserver" GIT_SSH_PORT=22 bash create_ssh_key.sh
```

---

### `add_remote_host.sh`

Creates an Ed25519 SSH key for a remote machine (e.g. a home server or Tailscale node), copies the public key to that machine, and wires up `~/.ssh/config`.

**What it does:**
- Prompts for a host alias, remote hostname/IP, username, port, key filename, and optional passphrase
- Optionally accepts the remote account password (uses `sshpass` when available to avoid interactive prompts; install with `brew install sshpass`)
- Copies the public key to the remote's `authorized_keys` using BatchMode → sshpass → interactive fallback, then verifies the key actually landed
- Updates `~/.ssh/config` with a `Host` block (idempotent)
- Tests key-based auth before exiting

**Usage:**
```bash
bash add_remote_host.sh
# or pre-fill inputs via env vars:
HOST_ALIAS="homepc" REMOTE_HOST="192.168.1.100" REMOTE_USER="jane" PORT="22" bash add_remote_host.sh
```

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
