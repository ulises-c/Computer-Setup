# Ghostty Config

Source: [ghostty.org/docs/config](https://ghostty.org/docs/config)

The raw config file is [ghostty.config](ghostty.config) — `setup.sh` copies it to the XDG path automatically.

## File Locations

Loaded in this order (later files override earlier ones):

### XDG path — all platforms (macOS + Linux)
```
$XDG_CONFIG_HOME/ghostty/config.ghostty
```
Defaults to `~/.config/ghostty/config.ghostty` if `XDG_CONFIG_HOME` is not set.

### macOS-specific path — macOS only, loaded after XDG
```
~/Library/Application Support/com.mitchellh.ghostty/config.ghostty
```

Both locations are supported on macOS. Since the XDG path works cross-platform and is loaded first, it is preferred for a consistent setup across macOS and Linux.

## Config

```
theme = Dark Pastel
shell-integration = zsh
```
