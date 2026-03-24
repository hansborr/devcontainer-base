# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A shared Podman base image and project template for sandboxed Claude Code devcontainers. Two layers:

1. **Base image** (root `Dockerfile`) — built once via `./build.sh`, tagged `localhost/claude-devcontainer:latest`. Contains Node.js 22, zsh, Claude Code CLI, Rust, Python 3, build tools, Playwright deps, and an iptables firewall.
2. **Project templates** — copied into new project repos as `.devcontainer/`:
   - `.devcontainer/` — **minimal** (default). Single container, no database, no port forwarding, no compose. Just `devcontainer.json` + thin `Dockerfile`.
   - `.devcontainer-postgres/` — **full**. Docker Compose with app + PostgreSQL, port forwarding, entrypoint that auto-starts `npm run dev`.

## Commands

```bash
./build.sh                              # Build/rebuild the base image
./devcontainer-rebuild.sh ~/repos/foo   # Teardown + relaunch a project's containers
```

Containers are launched with `devcontainer up` using Podman:
```bash
devcontainer up --workspace-folder . --docker-path podman --docker-compose-path podman-compose
```

## Architecture

- `Dockerfile` — base image. All shared tooling lives here. Changes require `./build.sh` and then rebuilding downstream project containers.
- `init-firewall.sh` — baked into the base image at `/usr/local/bin/`. Runs at container start via `postStartCommand`. Sets iptables default DROP policy with allowlisted domains split into `REQUIRED_DOMAINS` (abort on failure) and `OPTIONAL_DOMAINS` (warn and continue). Uses `ipset` for efficient IP matching. GitHub IPs are fetched dynamically from the `/meta` API and aggregated via `aggregate`. After applying rules, the script self-verifies by confirming `example.com` is blocked and `api.github.com` is reachable.
- `.devcontainer/devcontainer.json` — minimal template. Uses `runArgs` for `--init`, `--cap-add`, `--userns=keep-id` (no compose needed). Mounts named volumes directly.
- `.devcontainer-postgres/docker-compose.yml` — full template compose file. App service uses `init: true` (catatonit as PID 1 for zombie reaping), `userns_mode: "keep-id"` for rootless Podman UID mapping, and `cap_add: NET_ADMIN/NET_RAW` for the firewall.
- `.devcontainer-postgres/container-entrypoint.sh` — waits up to 10 minutes for `node_modules` (postCreateCommand may still be running), starts `npm run dev` in background, then `exec sleep infinity`. Logs to `/workspace/logs/dev-servers.log`.
- Named volumes (`claude-config`, `shell-history`, `npm-cache`, `playwright-cache`) persist across container rebuilds. The `:U` suffix maps ownership for rootless Podman.

### Rebuild chain

Changes propagate in order: `init-firewall.sh` or `Dockerfile` → `./build.sh` (rebuilds base image) → `./devcontainer-rebuild.sh ~/repos/<project>` (rebuilds each downstream project container). Changes to `.devcontainer/` template files only need copying into the target project and rebuilding that project's container.

### Container lifecycle

The container runs as user `node` (non-root). The firewall and `fw-install` scripts are the only commands granted passwordless sudo (via `/etc/sudoers.d/node-firewall`).

**Minimal template:** `postStartCommand` runs the firewall on every start. No other lifecycle hooks.

**Postgres template:** lifecycle hooks run in order:
1. `postCreateCommand` (`npm install`) — runs once on first container create
2. `postStartCommand` (`sudo /usr/local/bin/init-firewall.sh`) — runs on every start
3. `container-entrypoint.sh` — the container's main `command`, waits for npm install then starts dev servers

### Template setup for new projects

**Minimal:** Copy `.devcontainer/` into the project. No further configuration needed.

**Postgres:** Copy `.devcontainer-postgres/` into the project as `.devcontainer/`, then `cp .env.example .env` and set `PROJECT_NAME`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`. The compose file uses `${PROJECT_NAME}` to namespace container names and volumes.

## Firewall domain management

To allow a new domain, add it to `REQUIRED_DOMAINS` or `OPTIONAL_DOMAINS` in `init-firewall.sh`, then rebuild the base image. `REQUIRED_DOMAINS` failures abort container startup; `OPTIONAL_DOMAINS` failures only log warnings.

To temporarily install apt packages without permanently modifying the base image:
```bash
sudo fw-install poppler-utils    # from inside the container
```
This opens the firewall, runs `apt-get install`, then restores the firewall. Packages installed this way do not persist across container rebuilds.
