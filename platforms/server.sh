#!/usr/bin/env bash
# Headless server (Ubuntu Server LTS) profile: apt + snap, no GUI packages,
# SSH/Tailscale/Docker services, homepage dashboard stack.
# (The Raspberry Pi — Debian proper, no snapd — is a future target; TODO.md.)

CONFIG_SRC_DIR="$SETUP_ROOT/linux-server"

server_apt_install_tier() {
  local priority="$1" names
  names=$(pkg_names apt "$priority")
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  run sudo apt install -y $names
}

platform_main() {
  apt_bootstrap

  printf '\n==> Installing high-priority packages...\n'
  server_apt_install_tier high

  printf '\n==> Installing medium-priority packages...\n'
  server_apt_install_tier medium

  printf '\n==> Installing snap packages...\n'
  snap_install_tier medium

  if [[ "$INCLUDE_OPTIONAL" == true ]]; then
    printf '\n==> Installing optional (low) packages...\n'
    server_apt_install_tier low
  fi

  setup_bat_fd_symlinks
  set_default_shell

  # ── antidote (zsh plugin manager — no noble apt package) ───────────────────
  printf '\n'
  if [[ -f "$HOME/.antidote/antidote.zsh" ]]; then
    printf '==> antidote already installed\n'
  else
    printf '==> Installing antidote...\n'
    run_eval "$(custom_cmd zsh-antidote)"
  fi

  printf '\n'
  deploy_zshrc
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/tmux.conf" "$HOME/.tmux.conf" "tmux.conf" yes
  printf '\n'
  deploy_config "$CONFIG_SRC_DIR/zsh_plugins.txt" "$HOME/.zsh_plugins.txt" "linux-server/zsh_plugins.txt (platform override)" no

  # Pre-clone the plugins now (network is up — antidote itself just cloned);
  # otherwise the first interactive login does the GitHub clones lazily.
  printf '\n==> Pre-cloning antidote plugins...\n'
  run zsh -c 'source "$HOME/.antidote/antidote.zsh" && antidote bundle <"$HOME/.zsh_plugins.txt" >/dev/null'

  # ── Tailscale ───────────────────────────────────────────────────────────────
  printf '\n'
  if ! command -v tailscale &>/dev/null; then
    printf '==> Installing Tailscale...\n'
    run_eval "$(custom_cmd tailscale)"
  else
    printf '==> Tailscale already installed (%s)\n' "$(tailscale version | head -1)"
  fi
  printf "    Run 'sudo tailscale up' to authenticate and connect to your Tailnet.\n"

  # ── Docker ──────────────────────────────────────────────────────────────────
  printf '\n'
  if ! command -v docker &>/dev/null; then
    printf '==> Installing Docker...\n'
    run_eval "$(custom_cmd docker-ce)"
    run sudo usermod -aG docker "$USER"
    printf '    Docker installed. Log out and back in for the docker group to take effect.\n'
  else
    printf '==> Docker already installed (%s)\n' "$(docker --version | head -1)"
  fi

  # ── Cockpit ─────────────────────────────────────────────────────────────────
  printf '\n'
  if systemctl is-active --quiet cockpit.socket 2>/dev/null; then
    printf '==> Cockpit already running\n'
  else
    printf '==> Enabling cockpit...\n'
    run sudo systemctl enable --now cockpit.socket
  fi

  # ── Tailscale web service ───────────────────────────────────────────────────
  printf '\n'
  local service_dst="$HOME/.config/systemd/user/tailscale-web.service"
  if [[ ! -f "$service_dst" ]] || ! diff -q "$CONFIG_SRC_DIR/tailscale-web.service" "$service_dst" &>/dev/null; then
    printf '==> Installing Tailscale web service...\n'
    run mkdir -p "$HOME/.config/systemd/user"
    run cp "$CONFIG_SRC_DIR/tailscale-web.service" "$service_dst"
    run systemctl --user daemon-reload
    run systemctl --user enable --now tailscale-web
  else
    printf '==> Tailscale web service already installed\n'
  fi
  run loginctl enable-linger "$USER"

  # ── claude-code ─────────────────────────────────────────────────────────────
  printf '\n'
  if ! command -v claude &>/dev/null; then
    printf '==> Installing claude-code...\n'
    run_eval "$(custom_cmd claude-code)"
  else
    printf '==> claude-code already installed\n'
  fi

  # ── AdGuard: free port 53 ───────────────────────────────────────────────────
  printf '\n'
  local resolved_conf="/etc/systemd/resolved.conf"
  if ! grep -q "^DNSStubListener=no" "$resolved_conf" 2>/dev/null; then
    printf '==> Freeing port 53 for AdGuard...\n'
    run sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' "$resolved_conf"
    run sudo systemctl restart systemd-resolved
  else
    printf '==> Port 53 already free for AdGuard\n'
  fi

  # ── Docker .env files ───────────────────────────────────────────────────────
  printf '\n'
  printf '==> Setting up Docker service .env files...\n'
  local svc
  for svc in homepage speedtest-tracker filebrowser tailscale-proxy; do
    if [[ -f "$CONFIG_SRC_DIR/$svc/.env.example" && ! -f "$CONFIG_SRC_DIR/$svc/.env" ]]; then
      run cp "$CONFIG_SRC_DIR/$svc/.env.example" "$CONFIG_SRC_DIR/$svc/.env"
      printf '  created %s/.env\n' "$svc"
    else
      printf '  ✓ %s/.env\n' "$svc"
    fi
  done

  # Fill derivable values into homepage/.env (replace placeholders or append if missing)
  local homepage_env="$CONFIG_SRC_DIR/homepage/.env"
  if [[ -f "$homepage_env" ]]; then
    _fill_env() {
      local key="$1" val="$2"
      if [[ "$DRY_RUN" == true ]]; then
        printf '  [dry-run] %s → %s\n' "$key" "$val"
        return
      fi
      if grep -q "^$key=" "$homepage_env"; then
        sed -i "s|^$key=.*|$key=$val|" "$homepage_env"
      else
        echo "$key=$val" >> "$homepage_env"
      fi
      printf '  %s → %s\n' "$key" "$val"
    }

    _fill_env HOSTNAME "$(hostname)"
    _fill_env SERVER_IP "$(hostname -I | awk '{print $1}')"

    if command -v tailscale &>/dev/null; then
      local ts_hostname
      ts_hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
      if [[ -n "$ts_hostname" ]]; then
        _fill_env TAILSCALE_HOSTNAME "$ts_hostname"
      else
        printf "  TAILSCALE_HOSTNAME → (skipped — run 'tailscale up' then re-run setup.sh)\n"
      fi
    fi
  fi

  # Auto-generate APP_KEY for speedtest-tracker
  if [[ -f "$CONFIG_SRC_DIR/speedtest-tracker/.env" ]]; then
    if ! grep -qE "^APP_KEY=base64:.+" "$CONFIG_SRC_DIR/speedtest-tracker/.env" 2>/dev/null; then
      if [[ "$DRY_RUN" == true ]]; then
        printf '  [dry-run] generate APP_KEY in speedtest-tracker/.env\n'
      else
        local app_key
        app_key="base64:$(openssl rand -base64 32)"
        sed -i "s|^APP_KEY=.*|APP_KEY=$app_key|" "$CONFIG_SRC_DIR/speedtest-tracker/.env"
        printf '  auto-generated APP_KEY for speedtest-tracker\n'
      fi
    fi
  fi

  # ── Docker services ─────────────────────────────────────────────────────────
  printf '\n'
  printf '==> Starting Docker services...\n'
  local svc_dir
  for svc in homepage portainer glances speedtest-tracker filebrowser watchtower \
             uptime-kuma nginx-proxy-manager ntfy syncthing adguard tailscale-proxy; do
    svc_dir="$CONFIG_SRC_DIR/$svc"
    if [[ -d "$svc_dir" && -f "$svc_dir/docker-compose.yml" ]]; then
      printf '  %s...\n' "$svc"
      if ! run sudo docker compose -f "$svc_dir/docker-compose.yml" up -d; then
        printf '  Warning: %s failed to start\n' "$svc"
      fi
    fi
  done

  # ── Manual install reminders ────────────────────────────────────────────────
  custom_reminders_section

  # ── Done ────────────────────────────────────────────────────────────────────
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    printf 'Dry run complete — nothing was installed.\n'
    return 0
  fi
  printf '================================================================\n'
  printf ' Done. A few manual steps remain:\n'
  printf '================================================================\n'
  printf '\n'
  printf "  1. Log out and back in — activates zsh and 'docker' without sudo\n"
  printf '\n'
  printf '  2. Authenticate Tailscale:\n'
  printf '       sudo tailscale up\n'
  printf '       sudo tailscale set --operator=$USER\n'
  printf '\n'
  printf '  3. SSH / GPG keys:\n'
  printf '       bash SSH_and_GPG/create_ssh_key.sh\n'
  printf '       bash SSH_and_GPG/create_gpg_key.sh\n'
  printf '\n'
  printf '  4. Authenticate Tailscale, then re-run setup.sh to auto-fill TAILSCALE_HOSTNAME:\n'
  printf '       sudo tailscale up\n'
  printf '       bash setup.sh --profile server\n'
  printf '     Then fill in any remaining values in linux-server/homepage/.env and restart:\n'
  printf '       cd linux-server/homepage && docker compose restart\n'
  printf '\n'
  printf '================================================================\n'
  printf '\n'
  if command -v bat &>/dev/null; then
    bat "$CONFIG_SRC_DIR/post-install.md"
  else
    cat "$CONFIG_SRC_DIR/post-install.md"
  fi
}
