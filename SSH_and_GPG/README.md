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

### `ssh-agent-login-unlock.sh`

Asks for a passphrase-protected key's passphrase once, at the first interactive login, and keeps the key unlocked for a fixed time (default `15` minutes). It does this with one agent on a fixed socket, so every later shell and every non-interactive `ssh`/`git` call can use it.

**Why:** `AddKeysToAgent 15m` (from `create_ssh_key.sh`) only caches the key in the agent that `SSH_AUTH_SOCK` points to. A non-interactive session (`ssh host 'git pull'`, cron, a deploy script, an agent tool) never sources the shell's agent variables. It finds no agent, or an empty one, and fails with `Permission denied (publickey)` once the key has expired.

**What it does:**
- Adds a marked snippet to `~/.bashrc` (or `~/.zshrc` when `$SHELL` is zsh). The snippet starts `ssh-agent -a ~/.ssh/agent.sock -t <seconds>` when nothing is listening on that socket. In an interactive terminal it runs `ssh-add -t <seconds>` when the key is not already loaded. Ctrl-C skips. It also defines `sshkey_<name>` to reload the key by hand.
- Prepends a marked `Host <host>` block with `IdentityAgent ~/.ssh/agent.sock` to `~/.ssh/config`. ssh uses the first value it finds, so this block must come before any other block for the same host.
- Running it again replaces both blocks. `--remove` takes them out and leaves the rest of each file as it was.

**Usage:**
```bash
KEY_NAME=bitbucket GIT_HOST=bitbucket.org bash ssh-agent-login-unlock.sh
KEY_NAME=bitbucket GIT_HOST=bitbucket.org AGENT_TIMEOUT=30 bash ssh-agent-login-unlock.sh
KEY_NAME=bitbucket GIT_HOST=bitbucket.org bash ssh-agent-login-unlock.sh --remove
```

**Check:** `SSH_AUTH_SOCK=~/.ssh/agent.sock ssh-add -l` lists the key and its lifetime. After the lifetime ends it prints `The agent has no identities`, and the next interactive login asks again.

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
HOST_ALIAS="homepc" REMOTE_HOST="<server-ip>" REMOTE_USER="<username>" PORT="22" bash add_remote_host.sh
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
