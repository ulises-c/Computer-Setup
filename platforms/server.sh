#!/usr/bin/env bash
# Headless server (Ubuntu Server LTS) profile: apt + snap, no GUI packages.
# Shares the Linux install spine (linux_main) with the apt desktop — the
# apt/Tailscale/Docker hooks live in lib/core.sh. This module only carries the
# server tier composition and the server-only "step two" infra: SSH/Tailscale
# services, Docker dashboard stacks, cockpit, AdGuard.
# (The Raspberry Pi — Debian proper, no snapd — is a future target; docs/TODO.md.)

platform_bootstrap() {
  apt_bootstrap
}

# Pre-clone the antidote plugins now while the network is provably up; otherwise
# the first interactive login does the GitHub clones lazily.
server_preclone_antidote() {
  printf '\n==> Pre-cloning antidote plugins...\n'
  run zsh -c 'source /usr/share/zsh-antidote/antidote.zsh && antidote bundle <"$HOME/.zsh_plugins.txt" >/dev/null' \
    || printf 'warning: antidote pre-clone failed; plugins will clone on first login\n' >&2
}

server_ups_step() {
  pkg_selected nut || return 0

  local ups_dir="$CONFIG_SRC_DIR/ups"
  printf '\n==> Configuring NUT UPS monitoring...\n'
  if [[ -f "$ups_dir/.env" ]]; then
    run sudo bash "$ups_dir/setup.sh"
  else
    printf '  NUT is installed but not configured. Run:\n'
    printf '    cp %s/.env.example %s/.env\n' "$ups_dir" "$ups_dir"
    printf '    sudo bash %s/setup.sh\n' "$ups_dir"
  fi
}

# Pin Docker's address pools so compose networks never spill out of 172.16/12
# into home-LAN space (#75). Merged, not copied: the host's daemon.json carries
# other keys (e.g. the nvidia runtime) that must survive. "Up to date" means the
# file matches AND the running daemon reports the pools, so a run interrupted
# between install and restart is finished by the next run.
server_docker_daemon_step() {
  local src="$CONFIG_SRC_DIR/docker/daemon.json" dst="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
  local want current merged live exists=false file_ok=false bak=""
  printf '\n==> Pinning Docker default-address-pools...\n'

  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] merge %s into %s (dockerd --validate), restart docker if the file or the live pools differ, roll back if docker does not come back pinned\n' "$src" "$dst"
    return 0
  fi

  if ! command -v dockerd &>/dev/null; then
    printf 'warning: dockerd not found (snap or missing Docker install?); address pools not pinned\n' >&2
    return 0
  fi
  # sudo throughout: the docker group from a same-run install is not active yet,
  # and /etc/docker or daemon.json may be unreadable to the invoking user.
  if ! sudo docker info >/dev/null 2>&1; then
    printf 'warning: docker daemon not reachable; %s left alone — start docker, then re-run\n' "$dst" >&2
    return 0
  fi

  want="$(docker_pools_from_file "$src")"
  current='{}'
  if sudo test -e "$dst"; then
    exists=true
    current="$(sudo cat "$dst")"
    [[ -n "${current//[[:space:]]/}" ]] || current='{}'
  fi
  if ! merged="$(jq -S -n --argjson cur "$current" --slurpfile src "$src" '$cur * $src[0]' 2>/dev/null)"; then
    printf 'warning: %s is not a JSON object; leaving it alone\n' "$dst" >&2
    return 0
  fi
  [[ "$merged" == "$(jq -S . <<< "$current")" ]] && file_ok=true
  live="$(docker_pools_live sudo)" || live=""
  if [[ "$file_ok" == true && "$live" == "$want" ]]; then
    printf '  %s already up to date and live\n' "$dst"
    return 0
  fi

  if [[ "$file_ok" == false ]]; then
    if ! dockerd --validate --config-file <(printf '%s\n' "$merged") >/dev/null; then
      printf 'warning: merged daemon.json failed dockerd --validate; %s unchanged\n' "$dst" >&2
      return 0
    fi
    if [[ "$exists" == true ]]; then
      bak="$dst.bak.$(date +%Y%m%d_%H%M%S)"
      sudo cp -p "$dst" "$bak"
      # tee rewrites in place, keeping the file's owner and mode.
      sudo tee "$dst" >/dev/null <<< "$merged"
    else
      sudo install -D -m 644 /dev/stdin "$dst" <<< "$merged"
    fi
    printf '  %s updated%s\n' "$dst" "${bak:+ (backup: $bak)}"
  fi

  printf '  Restarting docker — every container restarts and host DNS (AdGuard) drops briefly...\n'
  if sudo systemctl restart docker && [[ "$(docker_pools_live sudo 2>/dev/null)" == "$want" ]]; then
    printf '  docker restarted with the pinned pools. docker0 is re-addressed from the new pool;\n'
    printf '  compose networks keep their old subnets until recreated — run verify.sh --profile server\n'
    printf '  and see linux-server/README.md step 8.\n'
    return 0
  fi

  printf 'error: docker did not come back with the pinned pools; rolling back\n' >&2
  if [[ -n "$bak" ]]; then
    sudo cp "$bak" "$dst"
  elif [[ "$exists" == false ]]; then
    sudo rm -f "$dst"
  else
    # The file was already pinned when this run started (an earlier run was
    # interrupted before its restart), so there is no pre-pin state to return to.
    printf 'error: %s was pinned before this run; no backup from this run — see %s.bak.*\n' "$dst" "$dst" >&2
  fi
  # A failed start trips docker.service's start limit; without reset-failed the
  # rollback restart is refused ("Start request repeated too quickly").
  sudo systemctl reset-failed docker
  if sudo systemctl restart docker; then
    printf 'error: docker is running again, but the pools are NOT pinned — journalctl -u docker\n' >&2
  else
    printf 'error: docker failed to start after rollback — journalctl -u docker\n' >&2
  fi
  return 1
}

# Server-only "step two": the headless service + dashboard layer that runs after
# the shared base install (packages, shell, dotfiles, Tailscale, Docker engine).
server_extras() {
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
  for svc in homepage speedtest-tracker filebrowser tailscale-proxy qbittorrent; do
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
             uptime-kuma nginx-proxy-manager ntfy syncthing adguard tailscale-proxy \
             qbittorrent; do
    svc_dir="$CONFIG_SRC_DIR/$svc"
    if [[ -d "$svc_dir" && -f "$svc_dir/docker-compose.yml" ]]; then
      printf '  %s...\n' "$svc"
      if ! run sudo docker compose -f "$svc_dir/docker-compose.yml" up -d; then
        printf '  Warning: %s failed to start\n' "$svc"
      fi
    fi
  done
}

server_footer() {
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

platform_main() {
  linux_main
}
