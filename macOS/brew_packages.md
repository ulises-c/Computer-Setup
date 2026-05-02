# List of useful brew packages

Install via `brew install <name>` unless noted otherwise.

1. gh | [brew](https://formulae.brew.sh/formula/gh) | [GitHub](https://github.com/cli/cli)
   1. GitHub CLI — create PRs, manage issues, clone repos, and trigger Actions from the terminal
2. hf | [brew](https://formulae.brew.sh/formula/hf) | [Docs](https://huggingface.co/docs/huggingface_hub/guides/cli)
   1. Hugging Face Hub CLI — download, upload, and manage ML models, datasets, and Spaces
3. git-lfs | [brew](https://formulae.brew.sh/formula/git-lfs) | [GitHub](https://github.com/git-lfs/git-lfs)
   1. Git extension for versioning large binary files (audio, video, datasets, model weights)
4. git-xet | [brew](https://formulae.brew.sh/formula/git-xet) | [GitHub](https://github.com/huggingface/xet-core)
   1. Git LFS plugin using the Xet protocol for efficient large ML model file storage on the Hugging Face Hub
5. fastfetch | [brew](https://formulae.brew.sh/formula/fastfetch) | [GitHub](https://github.com/fastfetch-cli/fastfetch)
   1. Fast, customizable system info display with full Apple Silicon chip and sensor support; shows on Ghostty startup in the example zshrc
6. pipx | [brew](https://formulae.brew.sh/formula/pipx) | [GitHub](https://github.com/pypa/pipx)
   1. Installs Python CLI tools in isolated virtual environments — avoids polluting the global Python install
7. pyenv | [brew](https://formulae.brew.sh/formula/pyenv) | [GitHub](https://github.com/pyenv/pyenv)
   1. Manages multiple Python versions and virtual environments
8. poppler | [brew](https://formulae.brew.sh/formula/poppler) | [Homepage](https://poppler.freedesktop.org/)
   1. PDF rendering library that ships useful CLI tools: `pdftotext`, `pdfimages`, `pdfinfo`, `pdftoppm`
9. sshpass | [brew](https://formulae.brew.sh/formula/sshpass)
   1. Non-interactive SSH password authentication — used by `add_remote_host.sh` to automate host setup
10. zsh-autosuggestions | [brew](https://formulae.brew.sh/formula/zsh-autosuggestions) | [GitHub](https://github.com/zsh-users/zsh-autosuggestions)
    1. Fish-style history-based suggestions for zsh — press → to accept
11. zsh-syntax-highlighting | [brew](https://formulae.brew.sh/formula/zsh-syntax-highlighting) | [GitHub](https://github.com/zsh-users/zsh-syntax-highlighting)
    1. Real-time syntax highlighting in zsh — valid commands appear green, invalid ones red, before pressing Enter
12. mongodb-community | [brew tap](https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-os-x/) | [Download](https://www.mongodb.com/try/download/community)
    1. MongoDB Community Server; installing via the `mongodb/brew` tap also provides `mongosh` and `mongodb-database-tools`
    2. Install: `brew tap mongodb/brew && brew install mongodb-community`
13. htop | [brew](https://formulae.brew.sh/formula/htop) | [GitHub](https://github.com/htop-dev/htop)
    1. Interactive process viewer — colorized, scrollable alternative to `top` with per-core CPU, memory, and swap meters
14. nvtop | [brew](https://formulae.brew.sh/formula/nvtop) | [GitHub](https://github.com/Syllo/nvtop)
    1. GPU process monitor similar to htop — supports NVIDIA, AMD, Intel, and Apple Silicon GPUs
15. asitop | [brew](https://formulae.brew.sh/formula/asitop) | [GitHub](https://github.com/tlkh/asitop)
    1. Performance monitoring TUI for Apple Silicon — shows CPU, GPU, ANE, memory bandwidth, and power usage in real time; requires `sudo`
