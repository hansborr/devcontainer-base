# devcontainer-base

Shared base image and project template for sandboxed Claude Code development containers using Podman.

## What's in the box

**Base image** (`Dockerfile`) — a batteries-included Node.js 22 dev environment:
- Zsh with Powerlevel10k, fzf, git-delta
- Claude Code CLI
- Rust toolchain
- Python 3 with pip/venv
- Build tools (gcc, make, cmake, pkg-config, libssl-dev)
- ripgrep, fd-find, htop, tmux, tree
- Playwright system dependencies for Chromium
- iptables firewall that restricts outbound traffic to an allowlist

**Project template** (`.devcontainer/`) — drop-in devcontainer config:
- Thin Dockerfile inheriting from the base image
- Docker Compose with app + PostgreSQL
- VS Code / devcontainer CLI configuration
- Entrypoint that auto-starts `npm run dev`

## Quick start

### 1. Build the base image (once)

```bash
./build.sh
```

This creates `localhost/claude-devcontainer:latest`.

### 2. Start a new project

Copy `.devcontainer/` into your project:

```bash
cp -r /path/to/devcontainer-base/.devcontainer ~/my-project/.devcontainer
```

Edit the config for your project:

```bash
cd ~/my-project/.devcontainer
cp .env.example .env
# Edit .env: set PROJECT_NAME, POSTGRES_DB, etc.
# Edit docker-compose.yml: adjust ports
# Edit devcontainer.json: adjust forwardPorts, postCreateCommand
```

Launch:

```bash
devcontainer up \
  --workspace-folder ~/my-project \
  --docker-path podman \
  --docker-compose-path podman-compose
```

## Rebuilding containers

After updating the base image, use the helper script to teardown and rebuild:

```bash
./devcontainer-rebuild.sh ~/my-project
```

## Firewall

The base image includes a firewall script (`init-firewall.sh`) that runs at container start via `postStartCommand`. It sets iptables to DROP by default and only allows outbound traffic to:

**Required** (failure blocks startup):
- GitHub (API, web, git — IP ranges from `/meta`)
- registry.npmjs.org
- api.anthropic.com

**Optional** (failure logs a warning):
- binaries.prisma.sh, cdn.playwright.dev, storage.googleapis.com
- sentry.io, statsig.anthropic.com, statsig.com
- VS Code marketplace and update servers

Plus: DNS (UDP 53), SSH (TCP 22), localhost, and the host network.

To add a domain, edit the `REQUIRED_DOMAINS` or `OPTIONAL_DOMAINS` arrays in `init-firewall.sh` and rebuild the base image.

## Customizing the project Dockerfile

The template Dockerfile is just:

```dockerfile
FROM localhost/claude-devcontainer:latest
```

Add project-specific layers as needed:

```dockerfile
FROM localhost/claude-devcontainer:latest

COPY start-servers.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/start-servers.sh
USER node
```

## File overview

```
Dockerfile              Base image definition
init-firewall.sh        Firewall allowlist (baked into base)
build.sh                Builds the base image
devcontainer-rebuild.sh Teardown + rebuild helper for projects
.devcontainer/          Project template (copy into your repo)
  .env.example          Environment variables template
  Dockerfile            Thin wrapper over base image
  docker-compose.yml    App + PostgreSQL services
  devcontainer.json     VS Code / devcontainer CLI config
  container-entrypoint.sh  Waits for npm install, starts dev servers
  start-servers.sh      Convenience script to restart dev servers
```
