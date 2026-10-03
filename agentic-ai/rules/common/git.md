# Git Remote Authentication

- `ssh-agent` may hold a key for only a limited window (`AddKeysToAgent <N>m`,
  set per key by `SSH_and_GPG/create_ssh_key.sh`); once it lapses the user must
  re-enter the passphrase themselves.
- `Permission denied (publickey)` means either that window lapsed or this
  machine has no key for that host — not every machine has a key for every
  forge. Either way it is not retryable: don't re-run the command or vary it,
  ask the user to re-authenticate in their terminal.
- Once they do, batch every pending remote git operation into that window.
