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
   2. **macOS Tahoe:** brew's Python bottles link against the system `libexpat`, which is missing symbols on Tahoe — causing `ensurepip` to fail. Use pyenv + expat instead (handled automatically by [setup.sh](setup.sh)):
      ```sh
      brew install pyenv expat
      pyenv install 3.12.13 && pyenv global 3.12.13
      export PIPX_DEFAULT_PYTHON="$HOME/.pyenv/versions/3.12.13/bin/python3.12"
      rm -rf ~/.local/pipx/shared
      ```
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
16. llama.cpp | [brew](https://formulae.brew.sh/formula/llama.cpp) | [GitHub](https://github.com/ggml-org/llama.cpp)
    1. LLM inference engine in C/C++ — run local models (GGUF format) on CPU and Apple Silicon GPU via Metal
17. mactop | [brew](https://formulae.brew.sh/formula/mactop) | [GitHub](https://github.com/metaspartan/mactop)
    1. Apple Silicon system monitor — shows CPU/GPU/ANE/memory/power usage in a real-time TUI; requires `sudo`
18. micro | [brew](https://formulae.brew.sh/formula/micro) | [GitHub](https://github.com/zyedidia/micro)
    1. Modern terminal text editor with mouse support, syntax highlighting, and familiar keybindings (Ctrl+S, Ctrl+C, etc.)
19. tmux | [brew](https://formulae.brew.sh/formula/tmux) | [GitHub](https://github.com/tmux/tmux)
    1. Terminal multiplexer — split panes, persist sessions across disconnects, and run background processes
20. ffmpeg | [brew](https://formulae.brew.sh/formula/ffmpeg) | [Homepage](https://ffmpeg.org/)
    1. Audio/video processing toolkit — convert, trim, encode, stream, and extract frames from media files
21. exiftool | [brew](https://formulae.brew.sh/formula/exiftool) | [Homepage](https://exiftool.org/)
    1. Read and write metadata (EXIF, IPTC, XMP) in photos, videos, and other files
22. tesseract | [brew](https://formulae.brew.sh/formula/tesseract) | [GitHub](https://github.com/tesseract-ocr/tesseract)
    1. OCR engine — extract text from images and scanned documents via CLI or library
23. smartmontools | [brew](https://formulae.brew.sh/formula/smartmontools) | [Homepage](https://www.smartmontools.org/)
    1. Monitor SSD/HDD health via S.M.A.R.T. data; `smartctl -a /dev/disk0` shows drive status
24. octave | [brew](https://formulae.brew.sh/formula/octave) | [Homepage](https://octave.org/)
    1. MATLAB-compatible numerical computing environment — matrix operations, plotting, and scripting
25. qemu | [brew](https://formulae.brew.sh/formula/qemu) | [Homepage](https://www.qemu.org/)
    1. Machine emulator and virtualizer — run x86, ARM, and other architectures on Apple Silicon
26. gogcli | [brew](https://formulae.brew.sh/formula/gogcli) | [Homepage](https://gogcli.sh/)
    1. Google Workspace CLI — Gmail, Calendar, Drive, Docs, Sheets, Slides, and more in the terminal; built for scripts, CI, and coding agents

## Casks

Install via `brew install --cask <name>`.

1. ghostty | [brew](https://formulae.brew.sh/cask/ghostty) | [Homepage](https://ghostty.org/)
   1. GPU-accelerated terminal emulator with native macOS feel, fast rendering, and extensive configuration
2. mac-mouse-fix | [brew](https://formulae.brew.sh/cask/mac-mouse-fix) | [Homepage](https://macmousefix.com/)
   1. Decouples mouse scroll speed/direction from trackpad settings — fixes the inverted/too-fast mouse scrolling on macOS
3. claude | [brew](https://formulae.brew.sh/cask/claude) | [Homepage](https://claude.ai/download)
   1. Anthropic's official Claude AI desktop app — chat, Projects, and extended context in a native macOS window
4. claude-code | [brew](https://formulae.brew.sh/cask/claude-code) | [Docs](https://docs.anthropic.com/en/docs/claude-code)
   1. Terminal-based AI coding assistant from Anthropic — agentic coding, file editing, shell commands, and MCP integrations
5. caffeine | [brew](https://formulae.brew.sh/cask/caffeine) | [Homepage](https://intelliscapesolutions.com/apps/caffeine)
   1. Simple menubar toggle to keep your Mac awake
6. rectangle | [brew](https://formulae.brew.sh/cask/rectangle) | [Homepage](https://rectangleapp.com/)
   1. Open source window management — snap windows with keyboard shortcuts or drag to screen edges
7. firefox | [brew](https://formulae.brew.sh/cask/firefox) | [Homepage](https://www.mozilla.org/en-US/firefox/)
   1. Open source web browser
8. visual-studio-code | [brew](https://formulae.brew.sh/cask/visual-studio-code) | [Homepage](https://code.visualstudio.com/)
   1. Code editor with extensions
9. readdle-spark | [brew](https://formulae.brew.sh/cask/readdle-spark) | [Homepage](https://sparkmailapp.com/)
   1. Smart email client by Readdle with AI features and clean cross-device sync
10. notion | [brew](https://formulae.brew.sh/cask/notion) | [Homepage](https://www.notion.com/)
    1. Notes and project management
11. obs | [brew](https://formulae.brew.sh/cask/obs) | [Homepage](https://obsproject.com/)
    1. Open source broadcasting and screen recording
12. vlc | [brew](https://formulae.brew.sh/cask/vlc) | [Homepage](https://www.videolan.org/vlc/)
    1. Open source media player for nearly every format
13. google-drive | [brew](https://formulae.brew.sh/cask/google-drive) | [Homepage](https://www.google.com/drive/download/)
    1. Google Drive desktop client
14. amazon-photos | [brew](https://formulae.brew.sh/cask/amazon-photos) | [Homepage](https://www.amazon.com/Amazon-Photos/b?node=13234696011)
    1. Unlimited full-resolution photo backup for Amazon Prime members
