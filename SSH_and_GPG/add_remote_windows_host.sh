#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  add_remote_windows_host.sh
      Create a key for a Windows machine running OpenSSH Server, install it
      there with PowerShell, and write its ~/.ssh/config block. Inputs are
      prompted for, or read from HOST_ALIAS, REMOTE_HOSTS (or REMOTE_HOST),
      REMOTE_USER, PORT and KEY_NAME. For Linux/macOS remotes use
      add_remote_host.sh.

  add_remote_windows_host.sh --add-address <alias> <address>...
      Add addresses to an alias that already has a block.

Addresses you give go first, in your order; addresses already stored for the
alias keep their order after them. Giving a stored address moves it forward.

An alias can have several addresses (IPs, <hostname>.local, ...), tried in
order: the first that accepts a TCP connection on the SSH port is used, and the
last one is the fallback. The host key is pinned to the alias, so a new address
for the same machine does not trigger a host-key warning, while a different
machine at a stale address still does.
EOF
}

SSH_DIR="$HOME/.ssh"
CFG_PATH="$SSH_DIR/config"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

# Lowercase only: ssh lowercases HostKeyAlias, so a pin for "Lab" would never match.
valid_alias() {
  [[ "$1" =~ ^[a-z0-9._-]+$ && "$1" != -* ]] || die "invalid alias: $1 (use lowercase letters, digits, '.', '_' or '-')"
}

# Addresses end up inside a Match exec command, so allow only host/IP characters
# (no %, which ssh would expand as a token).
valid_address() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ && "$1" != -* ]]
}

# The managed blocks use the same "add_remote_host.sh" markers as
# add_remote_host.sh, so either script can rewrite an alias the other created.
#
# Dies unless every add_remote_host.sh block is a closed, non-nested BEGIN..END
# pair and no alias has two; a bad pair would make the rewrite drop or keep the
# wrong lines.
check_markers() {
  [[ -f "$CFG_PATH" ]] || return 0
  awk '
    { sub(/\r$/, "") }
    index($0, "# BEGIN add_remote_host.sh: ") == 1 {
      name = substr($0, 29)
      if (open != "" || seen[name]++) exit 1
      open = name
    }
    index($0, "# END add_remote_host.sh: ") == 1 {
      if (substr($0, 27) != open) exit 1
      open = ""
    }
    END { if (open != "") exit 1 }
  ' "$CFG_PATH" || die "$CFG_PATH has unpaired, nested or repeated add_remote_host.sh markers; fix them by hand."
}

# extract: prints the alias's block. replace: prints the config with that block
# swapped, in place, for the contents of $3 (appended when the alias is new).
# A block from an earlier version of this script (a bare "Host <alias>" up to
# the next Host/Match/managed block) counts as the alias's block too.
config_blocks() {
  local mode="$1" alias="$2" block_file="${3:-}"
  [[ -f "$CFG_PATH" ]] || return 0
  awk -v mode="$mode" -v alias="$alias" -v block_file="$block_file" '
    BEGIN {
      begin = "# BEGIN add_remote_host.sh: " alias
      end = "# END add_remote_host.sh: " alias
    }
    { raw = $0; sub(/\r$/, "") }
    function is_stanza(line) {
      return line ~ /^[ \t]*([Hh][Oo][Ss][Tt]|[Mm][Aa][Tt][Cc][Hh])([ \t]|=)/
    }
    # "Host <alias>", "Host=<alias>" or with a trailing comment; one pattern only.
    function is_alias_host(line) {
      if (line !~ /^[ \t]*[Hh][Oo][Ss][Tt]([ \t]|=)/) return 0
      sub(/^[ \t]*[Hh][Oo][Ss][Tt][ \t]*=?[ \t]*/, "", line)
      sub(/[ \t]*(#.*)?$/, "", line)
      return line == alias
    }
    function put_new(    line) {
      if (placed) return
      while ((getline line < block_file) > 0) print line
      placed = 1
    }
    $0 == begin {
      managed = 1
      found = 1
      if (mode == "replace") put_new()
    }
    managed {
      if (mode == "extract") print
      if ($0 == end) managed = 0
      next
    }
    legacy && /^[ \t]*(#.*)?$/ { pending = pending raw "\n"; next }
    legacy && (is_stanza($0) || index($0, "# BEGIN ") == 1) {
      legacy = 0
      if (mode == "replace") printf "%s", pending
      pending = ""
    }
    legacy { old = old pending $0 "\n"; pending = ""; next }
    is_alias_host($0) {
      legacy = 1
      if (mode == "replace") put_new()
      next
    }
    mode == "replace" { print raw }
    END {
      if (mode == "extract" && !found) printf "%s", old
      if (mode == "replace") {
        printf "%s", pending
        if (!placed) {
          if (NR > 0) print ""
          put_new()
        }
      }
    }
  ' "$CFG_PATH"
}

# Sets EXISTING_* from the alias's current block; its HostName lines, in order,
# are the addresses. EXISTING_EXTRA lists what a rewrite would drop or change.
read_existing_block() {
  local keyword value addr name
  check_markers "$1"
  EXISTING_ADDRESSES=()
  EXISTING_USER=""
  EXISTING_PORT=""
  EXISTING_KEY=""
  EXISTING_EXTRA=""
  while read -r name value rest; do
    keyword="$(tr '[:upper:]' '[:lower:]' <<< "$name")"
    if [[ -n "$rest" && "$keyword" != \#* && "$keyword" != host && "$keyword" != match ]]; then
      EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$name with several values"
      continue
    fi
    case "$keyword" in
      hostname) EXISTING_ADDRESSES+=("$value") ;;
      user|port|identityfile)
        if [[ "$keyword" == user && -z "$EXISTING_USER" ]]; then
          EXISTING_USER="$value"
        elif [[ "$keyword" == port && -z "$EXISTING_PORT" ]]; then
          EXISTING_PORT="$value"
        elif [[ "$keyword" == identityfile && -z "$EXISTING_KEY" ]]; then
          EXISTING_KEY="$value"
        else
          EXISTING_EXTRA+="${EXISTING_EXTRA:+, }a second $name"
        fi
        ;;
      userknownhostsfile)
        [[ "$value" == "$KNOWN_HOSTS" ]] || EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$name"
        ;;
      ""|\#*|host|match|hostkeyalias|addkeystoagent|usekeychain|identitiesonly) ;;
      *) EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$name" ;;
    esac
  done < <(config_blocks extract "$1")
  for addr in ${EXISTING_ADDRESSES[@]+"${EXISTING_ADDRESSES[@]}"}; do
    valid_address "$addr" || die "the existing block for $1 has an unexpected HostName: $addr"
  done
  [[ -z "$EXISTING_PORT" || "$EXISTING_PORT" =~ ^[0-9]+$ ]] || die "the existing block for $1 has an unexpected Port: $EXISTING_PORT"
}

dedupe_addresses() {
  local addr seen=" "
  ADDRESSES=()
  for addr in "$@"; do
    [[ "$seen" == *" $addr "* ]] && continue
    seen+="$addr "
    ADDRESSES+=("$addr")
  done
}

# Without nc every Match probe fails, and only the last address would ever be used.
require_nc_for_multiple() {
  if ((${#ADDRESSES[@]} > 1)) && ! command -v nc &>/dev/null; then
    die "several addresses need nc (netcat) to pick a reachable one; install it (e.g. apt install netcat-openbsd) and run again."
  fi
}

render_block() {
  local alias="$1" user="$2" port="$3" key="$4"
  shift 4
  local addresses=("$@") last=$(($# - 1)) i
  printf '# BEGIN add_remote_host.sh: %s\n' "$alias"
  for ((i = 0; i < last; i++)); do
    printf 'Match originalhost %s exec "nc -z -w 1 %s %s"\n' "$alias" "${addresses[i]}" "$port"
    printf '  HostName %s\n' "${addresses[i]}"
  done
  printf 'Host %s\n' "$alias"
  printf '  HostName %s\n' "${addresses[last]}"
  printf '  HostKeyAlias %s\n' "$alias"
  printf '  UserKnownHostsFile %s\n' "$KNOWN_HOSTS"
  printf '  User %s\n' "$user"
  printf '  Port %s\n' "$port"
  printf '  AddKeysToAgent yes\n'
  if [[ "$(uname)" == "Darwin" ]]; then
    printf '  UseKeychain yes\n'
  fi
  printf '  IdentityFile %s\n' "$key"
  printf '  IdentitiesOnly yes\n'
  printf '# END add_remote_host.sh: %s\n' "$alias"
}

write_config() {
  local alias="$1" tmp_cfg block_file
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$CFG_PATH"
  tmp_cfg="$(mktemp "$SSH_DIR/config.XXXXXX")"
  block_file="$(mktemp "$SSH_DIR/config-block.XXXXXX")"
  render_block "$@" > "$block_file"
  config_blocks replace "$alias" "$block_file" > "$tmp_cfg"
  rm -f "$block_file"
  chmod 600 "$tmp_cfg"
  if ! verify_effective "$tmp_cfg" "$@"; then
    rm -f "$tmp_cfg"
    die "another entry in $CFG_PATH (e.g. an earlier Host * or multi-name Host line) overrides the block for $alias, sets a proxy for it, or adds trust sources besides $KNOWN_HOSTS (UserKnownHostsFile, KnownHostsCommand); nothing was changed."
  fi
  mv "$tmp_cfg" "$CFG_PATH"
}

# OpenSSH keeps the first value it sees, so an earlier matching entry would win.
verify_effective() {
  local cfg="$1" alias="$2" user="$3" port="$4" key="$5" out
  shift 5
  out="$(ssh -G -F "$cfg" "$alias" 2>/dev/null)" || return 1
  grep -Fx "user $user" <<< "$out" >/dev/null &&
    grep -Fx "port $port" <<< "$out" >/dev/null &&
    grep -Fx "hostkeyalias $alias" <<< "$out" >/dev/null &&
    grep -Fx "identitiesonly yes" <<< "$out" >/dev/null &&
    ! grep -Eq '^(proxycommand|proxyjump) ' <<< "$out" &&
    awk -v kh="$KNOWN_HOSTS" '$1 == "userknownhostsfile" { sub(/^~/, ENVIRON["HOME"], $2); ok = NF == 2 && $2 == kh } END { exit !ok }' <<< "$out" &&
    awk '$1 == "knownhostscommand" && $2 != "none" { bad = 1 } END { exit bad }' <<< "$out" &&
    awk -v key="${key/#\~/$HOME}" '$1 == "identityfile" { sub(/^~/, ENVIRON["HOME"], $2); if ($2 == key) ok = 1 } END { exit !ok }' <<< "$out" &&
    awk -v list=" $* " '$1 == "hostname" { ok = index(list, " " $2 " ") > 0 } END { exit !ok }' <<< "$out"
}

known_hosts_name() {
  if [[ "$2" == 22 ]]; then
    printf '%s' "$1"
  else
    printf '[%s]:%s' "$1" "$2"
  fi
}

# Sets HOST_KEY_PINS to known_hosts lines that pin the alias to the keys already
# trusted for its addresses, so an existing host moves to HostKeyAlias without a
# new trust-on-first-use. Every address with known keys must share a key with
# the first one and have no key of the same type that differs; otherwise they may
# be different machines, and this dies before anything is written.
# Prints "<type> <key>" for each known_hosts entry of name $1 (already in
# known_hosts form): plain keys, or with $2 = revoked, @revoked ones.
known_keys() {
  [[ -f "$KNOWN_HOSTS" ]] || return 0
  { ssh-keygen -F "$1" -f "$KNOWN_HOSTS" 2>/dev/null || true; } |
    awk -v want="${2:-plain}" '
      /^#/ || NF < 3 { next }
      $1 == "@revoked" { if (want == "revoked" && NF >= 4) print $3, $4; next }
      $1 ~ /^@/ { next }
      want == "plain" { print $2, $3 }
    '
}

alias_is_pinned() {
  [[ -n "$(known_keys "$1")" ]]
}

plan_host_key_pins() {
  local alias="$1" port="$2" addr entries="" name
  shift 2
  HOST_KEY_PINS=""
  [[ -f "$KNOWN_HOSTS" ]] || return 0
  for name in "$alias" "$@"; do
    [[ "$name" == "$alias" ]] || name="$(known_hosts_name "$name" "$port")"
    if [[ -n "$(known_keys "$name" revoked)" ]]; then
      die "known_hosts has a @revoked key for $name; resolve it by hand before using $alias."
    fi
  done
  alias_is_pinned "$alias" && return 0
  for addr in "$@"; do
    entries+="$(known_keys "$(known_hosts_name "$addr" "$port")" | awk -v addr="$addr" '{ print addr, $0 }')"$'\n'
  done
  # Exit 3 = conflict. The anchor is the first address with known keys; every
  # other address must share one of its keys and have no other key of a type
  # the anchor has.
  if ! HOST_KEY_PINS="$(awk -v alias="$alias" '
    !NF { next }
    anchor == "" { anchor = $1 }
    $1 == anchor {
      if (($2 in anchor_type) && !anchor_key[$2 FS $3]) exit 3
      if (!seen[$2 FS $3]++) pins[++n] = $2 FS $3
      anchor_type[$2] = 1
      anchor_key[$2 FS $3] = 1
      next
    }
    {
      others[$1] = 1
      if (anchor_key[$2 FS $3]) shared[$1] = 1
      else if ($2 in anchor_type) differs[$1] = 1
    }
    END {
      for (a in others) if (differs[a] || !shared[a]) exit 3
      for (i = 1; i <= n; i++) print alias, pins[i]
    }
  ' <<< "$entries")"; then
    die "known_hosts has host keys for the addresses of $alias that do not match each other, so they may be different machines. Remove the stale entries (ssh-keygen -R <address>) and run again."
  fi
}

# First use of an alias with no trusted key: show the fingerprint of the address
# the key will be copied to and ask, instead of trusting whatever answers there
# (with several addresses, a stale one may now belong to another machine).
confirm_host_key() {
  local alias="$1" addr="$2" port="$3" scanned yn
  [[ -n "$HOST_KEY_PINS" ]] && return 0
  alias_is_pinned "$alias" && return 0
  scanned="$(ssh-keyscan -p "$port" -T 5 "$addr" 2>/dev/null | awk '!/^#/ && NF >= 3 { print $2, $3 }' || true)"
  [[ -n "$scanned" ]] || die "could not read the host key of $addr port $port."
  printf '\nNo host key is trusted for %s yet. %s port %s presents:\n' "$alias" "$addr" "$port"
  awk -v a="$addr" '{ print a, $0 }' <<< "$scanned" | ssh-keygen -lf - | sed 's/^/  /'
  printf 'Compare with the output of "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" on that machine.\n'
  read -r -p "Trust this machine as $alias? (y/N): " yn
  [[ "$yn" == y || "$yn" == Y ]] || die "host key not trusted; nothing was changed."
  HOST_KEY_PINS="$(awk -v alias="$alias" '{ print alias, $1, $2 }' <<< "$scanned")"
}

apply_host_key_pins() {
  [[ -n "$HOST_KEY_PINS" ]] || return 0
  if [[ -s "$KNOWN_HOSTS" && -n "$(tail -c 1 "$KNOWN_HOSTS")" ]]; then
    printf '\n' >> "$KNOWN_HOSTS"
  fi
  printf '%s\n' "$HOST_KEY_PINS" >> "$KNOWN_HOSTS"
  printf 'Pinned the host key to %s in %s.\n' "$1" "$KNOWN_HOSTS"
}

# Run a command with a hard wall-clock timeout; ConnectTimeout alone doesn't cover auth hangs
ssh_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local rc=0
  { sleep "$secs" && kill "$pid" 2>/dev/null; } &
  local watcher=$!
  wait "$pid" 2>/dev/null || rc=$?
  { kill "$watcher" && wait "$watcher"; } 2>/dev/null || true
  return $rc
}

test_alias() {
  printf '\nTesting SSH connection: ssh %s ...\n' "$1"
  if ssh_with_timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" exit < /dev/null 2>/dev/null; then
    printf 'Success: key-based auth is working.\n'
  else
    printf 'Connection test failed. Run "ssh %s" to see why.\n' "$1" >&2
    return 1
  fi
}

# Dies when the server banner shows a non-Windows SSH server, which needs
# add_remote_host.sh. Win32-OpenSSH sends "OpenSSH_for_Windows_<version>"; an
# unreadable banner is not an error, because the copy then fails on its own.
require_windows_remote() {
  local addr="$1" port="$2" banner
  banner="$(ssh-keyscan -p "$port" -T 5 "$addr" 2>&1 >/dev/null | awk '/SSH-/ && !f { print; f = 1 }' || true)"
  if [[ -n "$banner" && "$banner" != *OpenSSH_for_Windows* ]]; then
    die "$addr does not look like a Windows SSH server (${banner#* }); use add_remote_host.sh for it, or set SKIP_OS_CHECK=1."
  fi
}

# Key types accepted from the public key file, in bash and in the PowerShell body.
KEY_TYPE_RE='^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$'

# Prints the first line of public key file $1 as "<type> <key>[ <comment>]",
# with single spaces after the type and the key. Only this line is installed.
public_key_line() {
  local type blob comment
  read -r type blob comment < <(head -n 1 "$1" | tr -d '\r')
  printf '%s %s%s' "$type" "$blob" "${comment:+ $comment}"
}

# Dies unless the first line of $1 is a public key ssh-keygen can read. Only
# that line is checked, because only that line is installed. The comment may
# hold any printable text: it reaches the remote as base64 data, never as
# PowerShell source.
validate_public_key() {
  local line type blob tmp ok=0
  line="$(public_key_line "$1")"
  [[ "$line" != *[[:cntrl:]]* ]] || die "$1 has control characters in its first line."
  read -r type blob _ <<< "$line"
  [[ "$type" =~ $KEY_TYPE_RE && "$blob" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "$1 does not start with a supported key type and key."
  tmp="$(mktemp)"
  printf '%s\n' "$line" > "$tmp"
  ssh-keygen -l -f "$tmp" >/dev/null 2>&1 && ok=1
  rm -f "$tmp"
  ((ok)) || die "ssh-keygen cannot read the first line of $1."
}

# The PowerShell that installs the key, run on the remote after a
# "$keyB64 = '<base64 of the public key line>'" line. It runs in Windows
# PowerShell 5.1 (powershell.exe). A separate function because bash 3.2
# misparses a heredoc with backticks (PowerShell's escape character) inside $( ).
#
# Members of Administrators are not read from ~/.ssh/authorized_keys: the
# default sshd_config has "Match Group administrators" pointing them at
# %ProgramData%\ssh\administrators_authorized_keys, which sshd ignores unless
# only Administrators and SYSTEM can access it. A per-user file that another
# account can write to is ignored too. Whether sshd accepts the key is proved
# afterwards by logging in with only that key.
windows_key_script() {
  cat <<'PS'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$types = @('ssh-ed25519', 'ssh-rsa', 'ssh-dss', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521', 'sk-ssh-ed25519@openssh.com', 'sk-ecdsa-sha2-nistp256@openssh.com')
# FILE_WRITE_DATA, FILE_APPEND_DATA, WRITE_DAC, WRITE_OWNER, GENERIC_WRITE, GENERIC_ALL.
$writeRights = 0x500C0006
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or [bool]($id.Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' })
}
function Test-AdminFileUsed {
  $cfg = Join-Path (Join-Path $env:ProgramData 'ssh') 'sshd_config'
  try { if (Test-Path -LiteralPath $cfg) { return [bool](Select-String -LiteralPath $cfg -Pattern '^\s*Match\s+Group\s+administrators(\s|$)' -Quiet) } } catch { }
  $true
}
function Get-SidName($sid) {
  try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
}
function Assert-UserFileAcl($f) {
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $ok = @($me, 'S-1-5-32-544', 'S-1-5-18')
  $acl = Get-Acl -LiteralPath $f
  $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if ($ok -notcontains $owner) { throw "$f is owned by $(Get-SidName $owner), so sshd ignores it; make the account its owner and run again." }
  foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
    if ($r.AccessControlType -eq 'Allow' -and ([int64]$r.FileSystemRights -band $writeRights) -and $ok -notcontains $r.IdentityReference.Value) {
      throw "$(Get-SidName $r.IdentityReference.Value) can write to $f, so sshd ignores it; remove that permission and run again."
    }
  }
}
# The owner is set to Administrators too: an owner can always rewrite the ACL,
# so a file owned by one admin account is not protected by the two entries.
function Set-AdminFileAcl($f) {
  $acl = New-Object Security.AccessControl.FileSecurity
  $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($s in 'S-1-5-32-544', 'S-1-5-18') {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $s), 'FullControl', 'Allow')))
  }
  Set-Acl -LiteralPath $f -AclObject $acl
  $now = Get-Acl -LiteralPath $f
  $rules = @($now.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { '{0}:{1}:{2}' -f $_.IdentityReference.Value, $_.AccessControlType, [int]$_.FileSystemRights } | Sort-Object)
  if (-not $now.AreAccessRulesProtected -or ($rules -join ',') -ne 'S-1-5-18:Allow:2032127,S-1-5-32-544:Allow:2032127') {
    throw "could not restrict $f to Administrators and SYSTEM (it now allows: $($rules -join ', '))"
  }
  $owner = $now.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if ($owner -ne 'S-1-5-32-544' -and $owner -ne 'S-1-5-18') { throw "could not make Administrators the owner of $f (owner: $(Get-SidName $owner)); run as an elevated administrator." }
}
# "<type> <base64>" of an active key line, or $null. As sshd does, an options
# field may come first; it ends at the first space or tab outside double quotes
# (\" does not end a quote). Comparisons are ordinal: PowerShell's -contains
# and .NET's StartsWith are culture-aware and ignore characters such as a BOM,
# which sshd does not.
function Get-KeyId($line) {
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('#', [StringComparison]::Ordinal)) { return $null }
  $tok = @($t -split '\s+', 3)
  if ($tok.Count -ge 2 -and [Array]::IndexOf($types, $tok[0]) -ge 0) { return $tok[0] + ' ' + $tok[1] }
  $quoted = $false
  for ($i = 0; $i -lt $t.Length; $i++) {
    $c = $t[$i]
    if ($c -eq '\' -and $quoted -and $i + 1 -lt $t.Length -and $t[$i + 1] -eq '"') { $i++; continue }
    if ($c -eq '"') { $quoted = -not $quoted; continue }
    if (-not $quoted -and ($c -eq ' ' -or $c -eq "`t")) { break }
  }
  if ($quoted -or $i -ge $t.Length) { return $null }
  $tok = @($t.Substring($i).Trim() -split '\s+', 3)
  if ($tok.Count -ge 2 -and [Array]::IndexOf($types, $tok[0]) -ge 0) { return $tok[0] + ' ' + $tok[1] }
  $null
}
function Main {
  $line = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($keyB64))
  if ($line -match '[\x00-\x1f\x7f]') { throw 'the public key line has control characters' }
  $want = Get-KeyId $line
  if (-not $want -or -not $line.StartsWith($want, [StringComparison]::Ordinal)) { throw 'the public key line is not "<type> <key> [comment]"' }
  $adminFile = (Test-Admin) -and (Test-AdminFileUsed)
  if ($adminFile) { $dir = Join-Path $env:ProgramData 'ssh'; $file = Join-Path $dir 'administrators_authorized_keys' }
  else { $dir = Join-Path $env:USERPROFILE '.ssh'; $file = Join-Path $dir 'authorized_keys' }
  $text = ''
  if (Test-Path -LiteralPath $file) {
    $bytes = [IO.File]::ReadAllBytes($file)
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
      [Console]::Error.WriteLine("$file is UTF-16, which sshd cannot read; re-save it as UTF-8 and run again.")
      exit 2
    }
    # A BOM stays part of the first line, so a key there does not count as
    # present (sshd may not read it) and a clean copy is added.
    $text = [Text.Encoding]::UTF8.GetString($bytes)
  }
  # A new per-user file is created empty and checked before the key goes in, so
  # an unsafe inherited ACL stops the run without leaving a key behind.
  if (-not $adminFile) {
    $created = $false
    if (-not (Test-Path -LiteralPath $file)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      New-Item -ItemType File -Path $file | Out-Null
      $created = $true
    }
    try { Assert-UserFileAcl $file } catch { if ($created) { Remove-Item -LiteralPath $file -Force }; throw }
  }
  $present = [Array]::IndexOf([string[]]@($text -split "`n" | ForEach-Object { Get-KeyId $_ }), $want) -ge 0
  if (-not $present) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $prefix = ''
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n", [StringComparison]::Ordinal)) { $prefix = "`r`n" }
    [IO.File]::AppendAllText($file, $prefix + $line + "`r`n", (New-Object Text.UTF8Encoding $false))
  }
  if ($adminFile) { Set-AdminFileAcl $file }
  if ($present) { Write-Output "Key already in $file" } else { Write-Output "Key added to $file" }
  exit 0
}
try { Main } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
PS
}

# Prints the remote command that installs the public key in file $1. The key
# line travels as base64 inside a gzipped, base64 payload, so no part of it is
# PowerShell or cmd.exe syntax; the command itself is only base64 and fixed
# text, which cmd.exe and a PowerShell DefaultShell both pass through unchanged.
# gzip keeps it under cmd.exe's 8191-character limit for RSA-4096 keys.
windows_key_command() {
  local key_b64 payload
  key_b64="$(public_key_line "$1" | base64 | tr -d '\n')"
  payload="$({ printf "\$keyB64 = '%s'\n" "$key_b64"; windows_key_script | sed 's/^[[:space:]]*//'; } |
    gzip -c -9 | base64 | tr -d '\n')"
  printf '%s' "powershell -NoProfile -NonInteractive -Command \"iex((New-Object IO.StreamReader((New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(,[Convert]::FromBase64String('$payload'))), [IO.Compression.CompressionMode]::Decompress)))).ReadToEnd())\""
}

# Prints what to run on the Windows machine when the automatic copy fails: the
# same command the script sends, which picks the file and sets its ACL itself.
print_manual_install() {
  cat <<EOF

On the Windows machine, sign in as $REMOTE_USER, open PowerShell (as
administrator if $REMOTE_USER is one), and run this single line:

$(windows_key_command "$PUB_PATH")

Then run this script again; it skips the key it finds and checks the login.
EOF
}

# Sourced (by the tests), only define the functions above.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# ---- --add-address mode ----
if [[ "${1:-}" == "--add-address" ]]; then
  (($# >= 3)) || { usage >&2; exit 1; }
  HOST_ALIAS="$2"
  shift 2
  valid_alias "$HOST_ALIAS"
  for addr in "$@"; do
    valid_address "$addr" || die "invalid address: $addr"
  done
  read_existing_block "$HOST_ALIAS"
  ((${#EXISTING_ADDRESSES[@]} > 0)) || die "no Host block for $HOST_ALIAS in $CFG_PATH; run without --add-address first."
  [[ -n "$EXISTING_USER" && -n "$EXISTING_KEY" ]] || die "the block for $HOST_ALIAS has no User or IdentityFile; run without --add-address to rewrite it."
  [[ -z "$EXISTING_EXTRA" ]] || die "the block for $HOST_ALIAS also sets $EXISTING_EXTRA, which a rewrite would drop; edit it by hand."
  PORT="${EXISTING_PORT:-22}"
  dedupe_addresses "$@" "${EXISTING_ADDRESSES[@]}"
  require_nc_for_multiple
  plan_host_key_pins "$HOST_ALIAS" "$PORT" "${ADDRESSES[@]}"
  write_config "$HOST_ALIAS" "$EXISTING_USER" "$PORT" "$EXISTING_KEY" "${ADDRESSES[@]}"
  printf 'Addresses for %s, in order: %s\n' "$HOST_ALIAS" "${ADDRESSES[*]}"
  apply_host_key_pins "$HOST_ALIAS"
  test_alias "$HOST_ALIAS" || exit 1
  exit 0
fi

(($# == 0)) || { usage >&2; exit 1; }

# ---- Check dependencies ----
if ! command -v sshpass &>/dev/null; then
  echo "Note: sshpass is not installed. You will be prompted for the remote password manually during key installation."
  echo "      To avoid this: brew install sshpass  (or apt install sshpass)"
  echo ""
  USE_SSHPASS=false
else
  USE_SSHPASS=true
fi

# ---- Inputs (can be provided as env vars or will be prompted) ----
HOST_ALIAS="${HOST_ALIAS:-}"
REMOTE_HOSTS="${REMOTE_HOSTS:-${REMOTE_HOST:-}}"
REMOTE_USER="${REMOTE_USER:-}"
PORT="${PORT:-}"
KEY_NAME="${KEY_NAME:-}"

prompt() {
  local var_name="$1" label="$2" default="${3:-}"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then return 0; fi

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$label: " value
  fi

  if [[ -z "$value" ]]; then
    echo "Error: $var_name cannot be empty." >&2
    exit 1
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt HOST_ALIAS   "SSH alias (friendly name, e.g. homepc)"
prompt REMOTE_HOSTS "Remote addresses, space-separated, most preferred first (IPs or <hostname>.local)"
prompt REMOTE_USER  "Remote username"
prompt PORT         "SSH port" "22"
prompt KEY_NAME     "Key file name (no path)" "$HOST_ALIAS"

valid_alias "$HOST_ALIAS"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid port: $PORT"
[[ -n "$REMOTE_USER" && "$REMOTE_USER" != *[[:space:]]* ]] || die "invalid username: $REMOTE_USER"
read -r -a NEW_ADDRESSES <<< "${REMOTE_HOSTS//,/ }"
((${#NEW_ADDRESSES[@]} > 0)) || die "REMOTE_HOSTS cannot be empty."
for addr in "${NEW_ADDRESSES[@]}"; do
  valid_address "$addr" || die "invalid address: $addr"
done

# Re-running for an existing alias keeps its addresses, after the new ones.
read_existing_block "$HOST_ALIAS"
[[ -z "$EXISTING_EXTRA" ]] || die "the existing block for $HOST_ALIAS also sets $EXISTING_EXTRA, which a rewrite would drop; edit it by hand."
dedupe_addresses "${NEW_ADDRESSES[@]}" ${EXISTING_ADDRESSES[@]+"${EXISTING_ADDRESSES[@]}"}
require_nc_for_multiple
plan_host_key_pins "$HOST_ALIAS" "$PORT" "${ADDRESSES[@]}"

# The key copy goes to the first address that answers on the SSH port.
REMOTE_HOST="${ADDRESSES[${#ADDRESSES[@]} - 1]}"
if command -v nc &>/dev/null; then
  for addr in "${ADDRESSES[@]}"; do
    if nc -z -w 2 "$addr" "$PORT" 2>/dev/null; then
      REMOTE_HOST="$addr"
      break
    fi
  done
fi

[[ "${SKIP_OS_CHECK:-}" == 1 ]] || require_windows_remote "$REMOTE_HOST" "$PORT"
confirm_host_key "$HOST_ALIAS" "$REMOTE_HOST" "$PORT"

# ---- Remote account password (optional, used once for ssh-copy-id) ----
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
if [[ "$USE_SSHPASS" == true && -z "$REMOTE_PASSWORD" ]]; then
  read -r -s -p "Remote account password for $REMOTE_USER@$REMOTE_HOST (leave blank to be prompted later): " REMOTE_PASSWORD
  echo ""
  if [[ -n "$REMOTE_PASSWORD" ]]; then
    read -r -s -p "Confirm password: " REMOTE_PASSWORD2
    echo ""
    if [[ "$REMOTE_PASSWORD" != "$REMOTE_PASSWORD2" ]]; then
      echo "Error: passwords do not match." >&2
      exit 1
    fi
  fi
fi

# ---- Optional passphrase ----
SSH_PASSPHRASE="${SSH_PASSPHRASE:-}"
if [[ -z "$SSH_PASSPHRASE" ]]; then
  read -r -p "Add a passphrase to the key? (y/N): " use_passphrase
  case "${use_passphrase:-N}" in
    y|Y)
      read -r -s -p "Passphrase: " SSH_PASSPHRASE
      echo ""
      read -r -s -p "Confirm passphrase: " SSH_PASSPHRASE2
      echo ""
      if [[ "$SSH_PASSPHRASE" != "$SSH_PASSPHRASE2" ]]; then
        echo "Error: passphrases do not match." >&2
        exit 1
      fi
      ;;
    *)
      SSH_PASSPHRASE=""
      ;;
  esac
fi

KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_PATH="$KEY_PATH.pub"

# ---- Ensure ~/.ssh exists with correct perms ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- Create key if it doesn't exist ----
if [[ -f "$KEY_PATH" || -f "$PUB_PATH" ]]; then
  echo "Key already exists at: $KEY_PATH"
  read -r -p "Overwrite? (y/N): " yn
  case "${yn:-N}" in
    y|Y)
      rm -f "$KEY_PATH" "$PUB_PATH"
      ;;
    *)
      echo "Reusing existing key."
      ;;
  esac
fi

if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -C "$HOST_ALIAS" -f "$KEY_PATH" -N "$SSH_PASSPHRASE"
fi

chmod 600 "$KEY_PATH"
chmod 644 "$PUB_PATH"

# Checked before anything is written to ~/.ssh/config or the remote. cmd.exe
# rejects command lines longer than 8191 characters.
validate_public_key "$PUB_PATH"
CMD_LEN="$(windows_key_command "$PUB_PATH" | wc -c | tr -d ' ')"
((CMD_LEN <= 8000)) || die "the install command for $PUB_PATH is $CMD_LEN characters, over cmd.exe's limit; shorten the key's comment or use an ed25519 key."

# ---- Start or reuse ssh-agent ----
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  eval "$(ssh-agent -s)" >/dev/null
fi

# ---- Add key to agent (store passphrase in Keychain on macOS) ----
if [[ "$(uname)" == "Darwin" ]]; then
  ssh-add --apple-use-keychain "$KEY_PATH"
else
  ssh-add "$KEY_PATH"
fi

# ---- Update ~/.ssh/config idempotently ----
write_config "$HOST_ALIAS" "$REMOTE_USER" "$PORT" "$KEY_PATH" "${ADDRESSES[@]}"
printf 'Addresses for %s, in order: %s\n' "$HOST_ALIAS" "${ADDRESSES[*]}"
apply_host_key_pins "$HOST_ALIAS"

# ---- Copy public key to remote ----
echo ""
echo "Copying public key to $REMOTE_USER@$REMOTE_HOST:$PORT ..."
# -F /dev/null: the copy goes to exactly $REMOTE_HOST, whatever ~/.ssh/config says
# about that address; the host key was pinned to the alias above.
SSH_BASE_OPTS=(-F /dev/null -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  -o HostKeyAlias="$HOST_ALIAS" -o ConnectTimeout=10 -p "$PORT")
APPEND_CMD="$(windows_key_command "$PUB_PATH")"

copy_key() {
  # 1. BatchMode first (existing agent keys).
  if ssh_with_timeout 60 ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes \
      "$REMOTE_USER@$REMOTE_HOST" "$APPEND_CMD" < /dev/null 2>/dev/null; then
    echo "Key copied (BatchMode/agent auth)."
    return 0
  fi
  # 2. sshpass with password.
  if [[ "$USE_SSHPASS" == true && -n "$REMOTE_PASSWORD" ]]; then
    if ssh_with_timeout 60 sshpass -p "$REMOTE_PASSWORD" ssh "${SSH_BASE_OPTS[@]}" \
        -o PubkeyAuthentication=no "$REMOTE_USER@$REMOTE_HOST" "$APPEND_CMD" < /dev/null; then
      echo "Key copied (password auth)."
      return 0
    fi
  fi
  # 3. Interactive fallback: the user types the password at the prompt.
  if ssh "${SSH_BASE_OPTS[@]}" -o PubkeyAuthentication=no \
      "$REMOTE_USER@$REMOTE_HOST" "$APPEND_CMD" < /dev/null; then
    echo "Key copied (interactive auth)."
    return 0
  fi
  return 1
}

# Proves sshd accepts the new key: IdentitiesOnly limits ssh to that key (the
# agent may sign with it, which covers a passphrase), with no password and no
# certificate (a trusted <key>-cert.pub would log in without the raw key), to
# the same address and pinned host key.
key_login_works() {
  ssh_with_timeout 60 ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes \
    -o IdentitiesOnly=yes -o IdentityFile="$KEY_PATH" -o PasswordAuthentication=no \
    -o 'PubkeyAcceptedAlgorithms=-*-cert-v01@openssh.com' -o HostbasedAuthentication=no \
    -o KbdInteractiveAuthentication=no -o PreferredAuthentications=publickey \
    "$REMOTE_USER@$REMOTE_HOST" 'exit' < /dev/null 2>/dev/null
}

if ! copy_key; then
  echo "" >&2
  echo "Automatic key copy failed." >&2
  print_manual_install >&2
  exit 1
fi

if ! key_login_works; then
  cat >&2 <<EOF

The key was written, but $REMOTE_USER@$REMOTE_HOST does not accept it. sshd may
read a different file than the one above (check AuthorizedKeysFile and any
Match blocks in %ProgramData%\\ssh\\sshd_config), or reject that file's owner or
permissions; %ProgramData%\\ssh\\logs or the OpenSSH event log says which.
EOF
  exit 1
fi
echo "Login with only the new key works."

# Goes through the alias, so it exercises address selection and the pinned host key.
if ! test_alias "$HOST_ALIAS"; then
  exit 1
fi

echo ""
echo "Done. Connect any time with: ssh $HOST_ALIAS"
