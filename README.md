# devcontainer-base

Shared base image and project template for sandboxed Claude Code development containers using Podman.
Initially copied from https://github.com/anthropics/claude-code/tree/main/.devcontainer but modified to suit my needs.

## What's in the box

**Base image** (`Dockerfile`) — a batteries-included Node.js 24 dev environment:
- Zsh with Powerlevel10k, fzf, git-delta
- Claude Code CLI and OpenAI Codex CLI
- Rust toolchain (with `rust-analyzer`)
- TypeScript language server (`tsc` + `typescript-language-server`)
- Python 3 with pip/venv
- Build tools (gcc, make, cmake, pkg-config, libssl-dev)
- ripgrep, fd-find, htop, tmux, tree
- Playwright system dependencies for Chromium
- iptables firewall that restricts outbound traffic to an allowlist

**Project templates** — two drop-in devcontainer configs:
- `.devcontainer/` — minimal single-container setup, no database, no port forwarding
- `.devcontainer-postgres/` — full setup with Docker Compose, PostgreSQL, port forwarding, and auto-start entrypoint

## Quick start

### 1. Build the base image (once)

```bash
./build.sh
```

This creates `localhost/claude-devcontainer:latest`.

### 2. Start a new project

**Minimal** (no database) — copy `.devcontainer/` into your project:

```bash
cp -r /path/to/devcontainer-base/.devcontainer ~/my-project/.devcontainer
```

**With PostgreSQL** — copy `.devcontainer-postgres/` instead:

```bash
cp -r /path/to/devcontainer-base/.devcontainer-postgres ~/my-project/.devcontainer
cd ~/my-project/.devcontainer
cp .env.example .env
# Edit .env: set PROJECT_NAME, POSTGRES_DB, etc.
# Edit docker-compose.yml: adjust ports
# Edit devcontainer.json: adjust forwardPorts, postCreateCommand
```

Launch either setup:

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

## Persistence and SSH keys

State lives in three places:

- **`/workspace`** — your project code (bind-mounted from the host, version-controlled).
- **Per-project volumes** — `~/.claude` and `~/.codex` (auth, history, settings), shell history, and caches. They survive container rebuilds but are separate per project, so you log in to Claude/Codex once per project.
- **`/home/node/persist`** — a single volume **shared across every project**. Put personal scratch, notes, and downloaded tools here instead of loose in `/home/node`, which is wiped on rebuild. Create it once with `podman volume create persist` (the rebuild helper does this automatically).

**SSH key:** run `./seed-ssh-key.sh` once on the host. It copies your `~/.ssh` into the `persist` volume; every container then exposes it at `~/.ssh` via a symlink. Your key stays encrypted, and your real `~/.ssh` is never bind-mounted or SELinux-relabeled — relabeling it would risk locking `sshd` out of the host. Keep the passphrase out of any long-lived in-container `ssh-agent`.

## Moving to another machine

Claude/Codex logins, history, and the shared scratch are Podman volumes, not host files. To migrate:

```bash
# On the old machine:
./migrate-volumes.sh backup ~/dc-backup
# copy ~/dc-backup to the new machine (rsync/scp), then on the new machine:
./migrate-volumes.sh restore ~/dc-backup
./build.sh
./devcontainer-rebuild.sh ~/repos/<each-project>
```

`./migrate-volumes.sh list` shows exactly what will be backed up. The backup contains auth tokens and your encrypted SSH key — store it securely.

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

**Toggling the firewall** (from inside a container):

```bash
sudo fw off       # open egress (e.g. to let agents do web research)
sudo fw status    # show whether egress is restricted or open
sudo fw on        # re-apply the full allowlist firewall
sudo fw-install poppler-utils   # one-shot apt install, then auto re-secure
```

`fw off` only lasts the current session — the full firewall is re-applied on every container start. `fw-install` always re-secures afterwards, even if the install fails.

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
Dockerfile                  Base image definition
init-firewall.sh            Firewall allowlist (baked into base)
fw.sh                       Firewall on/off/status toggle -> /usr/local/bin/fw
fw-install.sh               One-shot apt install with auto re-secure (baked into base)
build.sh                    Builds the base image
devcontainer-rebuild.sh     Teardown + rebuild helper for projects
seed-ssh-key.sh             Copy ~/.ssh into the shared 'persist' volume (run once)
migrate-volumes.sh          Back up / restore Claude + Codex + persist volumes
.devcontainer/              Minimal template (single container, no DB)
  Dockerfile                Thin wrapper over base image
  devcontainer.json         VS Code / devcontainer CLI config
.devcontainer-postgres/     Full template (app + PostgreSQL)
  Dockerfile                Thin wrapper over base image
  docker-compose.yml        App + PostgreSQL services
  devcontainer.json         VS Code / devcontainer CLI config
  .env.example              Environment variables template
  container-entrypoint.sh   Waits for npm install, starts dev servers
  start-servers.sh          Convenience script to restart dev servers
```
