# macOS zshrc upgrade plan

Bring the macOS zshrc.example up to parity with the linux-desktop config,
which now has CachyOS Fish-style enhancements via antidote.

## Current state

The macOS zshrc manually sources two plugins from Homebrew:

```zsh
source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
```

No icons, no abbreviations, no substring search, no command duration, no
notify, no zoxide, no fzf keybindings, no bat man pages.

## Target state

Match linux-desktop/zshrc.example feature set while keeping macOS-specific
bits (Homebrew PATH, brew completions, `brewup` alias).

## Changes required

### 1. Switch to antidote

**Install:** `brew install antidote`

**Replace** the manual `source $(brew --prefix)/share/...` lines with:

```zsh
if [[ -f $(brew --prefix)/opt/antidote/share/antidote/antidote.zsh ]]; then
  source $(brew --prefix)/opt/antidote/share/antidote/antidote.zsh
  antidote load
fi
```

**Create** `macOS/zsh_plugins.txt` (identical to linux-desktop):

```
zsh-users/zsh-completions kind:fpath path:src
zsh-users/zsh-autosuggestions
zsh-users/zsh-syntax-highlighting
zsh-users/zsh-history-substring-search
olets/zsh-abbr
marzocchi/zsh-notify
```

This replaces two Homebrew-managed plugins with six antidote-managed ones.
The Homebrew `zsh-autosuggestions` and `zsh-syntax-highlighting` formulae
can be uninstalled afterward.

### 2. eza aliases with icons

**Prerequisite:** A Nerd Font must be set in Ghostty (e.g., JetBrains Mono
Nerd Font). Check ghostty.config.

**Replace** current eza block:

```zsh
alias ls='ls -G'
if command -v eza &>/dev/null; then
  alias ll='eza -lah --git'
  alias la='eza -a'
else
  ...
fi
```

**With:**

```zsh
alias ls='ls -G'
if command -v eza &>/dev/null; then
  alias ls='eza -al --color=always --icons --group-directories-first'
  alias ll='eza -lah --git --icons --group-directories-first'
  alias la='eza -a --icons --group-directories-first'
  alias lt='eza --tree --icons --level=2 --group-directories-first'
else
  ...
fi
```

**Packages needed:** `brew install eza` (may already be installed).

### 3. RPROMPT with command duration

**Add** the `_prompt_precmd` / `_prompt_preexec` hooks and RPROMPT from
linux-desktop/zshrc.example. Replace the simple `precmd() { vcs_info }`
with the full precmd that also tracks command duration.

```zsh
_prompt_precmd() {
  local exit_code=$?
  vcs_info
  _last_exit=$exit_code
  _cmd_end=$EPOCHSECONDS
  if (( _cmd_start > 0 && _cmd_end - _cmd_start >= 2 )); then
    local elapsed=$(( _cmd_end - _cmd_start ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    if (( mins > 0 )); then
      _cmd_duration="${mins}m${secs}s"
    else
      _cmd_duration="${secs}s"
    fi
  else
    _cmd_duration=""
  fi
  _cmd_start=0
}

_prompt_preexec() { _cmd_start=$EPOCHSECONDS }

precmd_functions+=(_prompt_precmd)
preexec_functions+=(_prompt_preexec)

RPROMPT='${_cmd_duration:+%F{242}${_cmd_duration}%f}'
```

### 4. Colorized man pages via bat

```zsh
if command -v bat &>/dev/null; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT="-c"
fi
```

**Packages needed:** `brew install bat` (may already be installed).

### 5. zsh-notify

On macOS, zsh-notify uses `terminal-notifier` instead of `notify-send`.

**Packages needed:** `brew install terminal-notifier`

**Config:**

```zsh
zstyle ':notify:*' command-complete-timeout 30
zstyle ':notify:*' error-title "Command failed"
zstyle ':notify:*' success-title "Command finished"
```

No `xdotool` needed — macOS focus detection uses native AppleScript.

### 6. Fish-style abbreviations

```zsh
if type abbr &>/dev/null; then
  abbr set -q gs='git status' 2>/dev/null
  abbr set -q ga='git add' 2>/dev/null
  abbr set -q gc='git commit' 2>/dev/null
  abbr set -q gp='git push' 2>/dev/null
  abbr set -q gl='git log --oneline --graph --decorate' 2>/dev/null
  abbr set -q ..='cd ..' 2>/dev/null
  abbr set -q ...='cd ../..' 2>/dev/null
fi
```

This replaces the existing static git aliases (`alias gs=...`) — abbr
expands inline so your history shows the real command.

### 7. History substring search

```zsh
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^[OA' history-substring-search-up
bindkey '^[OB' history-substring-search-down
```

### 8. Completion enhancements

```zsh
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}── %d ──%f'
```

### 9. Syntax highlighting config

```zsh
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
ZSH_HIGHLIGHT_STYLES[path]='fg=cyan,underline'
ZSH_HIGHLIGHT_STYLES[path_prefix]='fg=cyan,underline'
```

### 10. Zoxide

```zsh
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"
```

**Packages needed:** `brew install zoxide` (may already be installed).

### 11. FZF keybindings (Homebrew paths)

```zsh
[[ -f $(brew --prefix)/opt/fzf/shell/key-bindings.zsh ]] && \
  source $(brew --prefix)/opt/fzf/shell/key-bindings.zsh
[[ -f $(brew --prefix)/opt/fzf/shell/completion.zsh ]] && \
  source $(brew --prefix)/opt/fzf/shell/completion.zsh
```

**Packages needed:** `brew install fzf` (may already be installed).

## Packages to install (Homebrew)

```bash
brew install antidote eza bat zoxide fzf terminal-notifier
```

## Packages to uninstall (replaced by antidote)

```bash
brew uninstall zsh-autosuggestions zsh-syntax-highlighting
```

## Migration steps

1. Install new Homebrew packages
2. Create `~/.zsh_plugins.txt` from `macOS/zsh_plugins.txt`
3. Replace `~/.zshrc` with updated `macOS/zshrc.example`
4. Open new Ghostty terminal (antidote clones plugins on first load)
5. Uninstall replaced Homebrew formulae
6. Verify: icons, abbreviations, notifications, man pages, duration
