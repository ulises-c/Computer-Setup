# Useful Linux Desktop software

Tested on CachyOS (Arch-based). Most packages should work on other Arch or Debian-based distros with minor adjustments.

## Setup

```bash
bash linux-desktop/setup.sh [--work] [--personal] [--optional] [--dry-run]
```

`setup.sh` auto-detects the distro from `/etc/os-release`:

- **Arch / CachyOS** (and Manjaro, EndeavourOS, …) — installs via `yay` (repo + AUR),
  bootstrapping `yay` with `pacman` if it's missing.
- **Ubuntu / Debian** — installs via `apt` + `snap`, adding the eza / fastfetch / GitHub CLI repos as needed.

Either way, `pyenv` and `nvm` install via their official curl scripts (`~/.pyenv`, `~/.nvm`),
the login shell is switched to `zsh`, and the `zshrc` / antidote / Ghostty configs are
copied into place. Use `--dry-run` to preview every command without changing anything.

Package definitions and per-distro names live in
[`linux_desktop_packages.json`](linux_desktop_packages.json).

## Gaming

1. Bolt | [Codeberg](https://codeberg.org/Adamcake/Bolt)
   1. Open-source, third-party launcher for RuneScape and Old School RuneScape on Linux — replaces the Jagex Launcher which is not available on Linux
