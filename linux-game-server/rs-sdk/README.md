# RS-SDK server

This is the independent RS-SDK fork, which includes its own game engine, web client, and bot gateway. It is not layered on top of the vanilla Lost City instance. Compose builds the upstream `server/Dockerfile` from the clean checkout at `~/github/rs-sdk` (`RS_SDK_SOURCE_DIR`) and stores persistent state in `~/games/rs-sdk/data` (`RS_SDK_DATA_DIR`).

## Access

- LAN web client: `http://<server-ip>:8080/`
- Tailscale web client: `https://<game-host>.<tailnet>.ts.net:9445/`
- LAN game TCP: `<server-ip>:43595`
- LAN SDK gateway: `ws://<server-ip>:7781`
- Tailscale SDK gateway: `wss://<game-host>.<tailnet>.ts.net:9446`

The web UI uses root-relative routes, so it gets a dedicated Tailscale HTTPS port rather than a subpath. The browser game's `/gateway` WebSocket is proxied through the web server. The direct gateway and game TCP listeners are allowed only from the LAN and Tailscale interfaces. Internal ports are not opened: gateway 7780, management 8899, telemetry 43512, hiscores 8889, and the login, logger and friend servers on 43510, 43511 and 45109 (moved off the Lost City defaults, which that stack uses on the same host network). Tailscale Serve is tailnet-only; no Funnel or router port forwarding is configured.

The Compose service intentionally does not publish Docker ports: it uses host networking so the host UFW policy can restrict inbound sources. Do not add a Docker `ports:` mapping; Docker-published ports can bypass UFW.

## Operations

Build/initialize both projects with `bash linux-game-server/2004scape/setup.sh`, then activate with `bash linux-game-server/2004scape/activate.sh` after the one-time Lost City wizard completes.

```sh
docker compose --project-directory linux-game-server/rs-sdk -f linux-game-server/rs-sdk/docker-compose.yml ps
docker compose --project-directory linux-game-server/rs-sdk -f linux-game-server/rs-sdk/docker-compose.yml logs --tail=100 rs-sdk
```

User registration is enabled so LAN/tailnet users can create accounts. Keep the access boundary intact. The RS-SDK data directory contains SQLite databases and player saves; the nightly game backup covers it (see `2004scape/README.md`). Verify an actual restore before relying on it. Update the checkout and rebuild as a maintenance operation; this deployment does not auto-pull code.
