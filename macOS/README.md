# Useful macOS software

## Package Manager

1. Homebrew | [Download](https://brew.sh/)
   1. The missing package manager for macOS — see [brew_packages.md](brew_packages.md) for the full list of useful formulae
   2. Packages: `gh`, `hf`, `git-lfs`, `git-xet`, `fastfetch`, `pipx`, `pyenv`, `sshpass`, `gnupg`, `zsh-autosuggestions`, `zsh-syntax-highlighting`, `htop`, `nvtop`, `mactop`, `micro`, `tmux`, `llama.cpp`, and more
2. pipx | [brew](https://formulae.brew.sh/formula/pipx)
   1. Installs Python CLI tools in isolated virtual environments — see [pipx_packages.md](pipx_packages.md) for the full list
   2. Packages: `poetry`, and more

## Development

1. Ghostty | [Download](https://ghostty.org/) | [brew](https://formulae.brew.sh/cask/ghostty)
   1. GPU-accelerated terminal emulator — see [ghostty_config.md](ghostty_config.md) for config
   2. Install: `brew install --cask ghostty`
2. VS Code | [Download](https://code.visualstudio.com/download) | [brew](https://formulae.brew.sh/cask/visual-studio-code)
   1. IDE with extensions
   2. Install: `brew install --cask visual-studio-code`
3. Docker | [Download](https://www.docker.com/products/docker-desktop/) | [brew](https://formulae.brew.sh/cask/docker)
   1. Containerization platform for building and running isolated application environments
   2. Install: `brew install --cask docker`
4. Node.js | [Download](https://nodejs.org/) | [nvm](https://github.com/nvm-sh/nvm)
   1. JavaScript runtime — managed via nvm (see setup.sh); see [node_packages.md](node_packages.md) for global packages
   2. Install: `nvm install lts/* && nvm alias default lts/*`

## Utilities

1. Rectangle | [Download](https://rectangleapp.com/) | [brew](https://formulae.brew.sh/cask/rectangle)
   1. Open source window management app
   2. Install: `brew install --cask rectangle`
2. Caffeine | [brew](https://formulae.brew.sh/cask/caffeine) | [Homepage](https://intelliscapesolutions.com/apps/caffeine)
   1. Simple menubar toggle to keep your Mac awake — single click, no frills
   2. Install: `brew install --cask caffeine`
   3. Optional: **Amphetamine** | [Mac App Store](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) — more powerful alternative with scheduling, app triggers, and lid-closed support
3. Tailscale | [Download](https://tailscale.com/download) | [Mac App Store](https://apps.apple.com/us/app/tailscale/id1475387142)
   1. Zero-config VPN built on WireGuard — connect all your devices on a private network
   2. Install via App Store (recommended — network extension requires proper entitlements)
4. Bitwarden | [Download](https://bitwarden.com/download/) | [Mac App Store](https://apps.apple.com/us/app/bitwarden/id1352778147)
   1. Open source password manager
   2. Install via App Store (recommended — browser integration requires native messaging from App Store version)

## AI

1. Claude Desktop | [Download](https://claude.ai/download) | [brew](https://formulae.brew.sh/cask/claude)
   1. Anthropic's official Claude AI desktop app — chat, Projects, and extended context in a native macOS window
   2. Install: `brew install --cask claude`
2. Claude Code | [Docs](https://docs.anthropic.com/en/docs/claude-code) | [brew](https://formulae.brew.sh/cask/claude-code) | [npm](https://www.npmjs.com/package/@anthropic-ai/claude-code)
   1. Terminal-based AI coding assistant from Anthropic — agentic coding, file editing, shell commands, and MCP integrations
   2. Install (curl): `curl -fsSL https://claude.ai/install.sh | sh`
   3. Install (brew): `brew install --cask claude-code`
   4. Install (npm): `npm install -g @anthropic-ai/claude-code`

## Productivity

1. Notion | [Download](https://www.notion.com/desktop) | [brew](https://formulae.brew.sh/cask/notion)
   1. Notes and project management
   2. Install: `brew install --cask notion`
2. Goodnotes | [Mac App Store](https://apps.apple.com/us/app/goodnotes-6/id1444383602)
   1. Handwriting and note-taking app with Apple Pencil support; syncs across Mac and iPad
3. Spark | [Download](https://sparkmailapp.com/) | [brew](https://formulae.brew.sh/cask/readdle-spark)
   1. Smart email client with AI features and clean cross-device sync
   2. Install: `brew install --cask readdle-spark`

## Browsers

1. Firefox | [Download](https://www.mozilla.org/en-US/firefox/new/) | [brew](https://formulae.brew.sh/cask/firefox)
   1. Open source web browser
   2. Install: `brew install --cask firefox`

## Media & Creative

1. OBS | [Download](https://obsproject.com/) | [brew](https://formulae.brew.sh/cask/obs)
   1. Open source broadcasting and recording software
   2. Install: `brew install --cask obs`
2. VLC | [Download](https://www.videolan.org/vlc/) | [brew](https://formulae.brew.sh/cask/vlc)
   1. Open source media player for nearly every format
   2. Install: `brew install --cask vlc`
3. Photomator | [Mac App Store](https://apps.apple.com/us/app/photomator-photo-editor/id1444636541)
   1. Photo editor, free version & pay once
4. Pixelmator Pro | [Mac App Store](https://apps.apple.com/us/app/pixelmator-pro/id1289583905?mt=12)
   1. Photo editor, pay once

## Cloud Storage

1. Google Drive | [Download](https://www.google.com/drive/download/) | [brew](https://formulae.brew.sh/cask/google-drive)
   1. Google Drive cloud storage desktop client
   2. Install: `brew install --cask google-drive`
2. Amazon Photos | [Download](https://www.amazon.com/Amazon-Photos/b?node=13234696011) | [brew](https://formulae.brew.sh/cask/amazon-photos)
   1. Unlimited full-resolution photo backup for Amazon Prime members
   2. Install: `brew install --cask amazon-photos`
