# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A shared Podman base image and project template for sandboxed Claude Code devcontainers. Two layers:

1. **Base image** (root `Dockerfile`) — built once via `./build.sh`, tagged `localhost/claude-devcontainer:latest`. Contains Node.js 24, zsh, Claude Code CLI, OpenAI Codex CLI, Rust (with `rust-analyzer`), the TypeScript language server, Python 3, build tools, Playwright deps, and an iptables firewall. It also bakes in a shared ssh-agent and the `claude`/`codex` skip-prompt aliases (see [Shell defaults](#shell-defaults-baked-into-the-image)).
2. **Project templates** — copied into new project repos as `.devcontainer/`:
   - `.devcontainer/` — **minimal** (default). Single container, no database, no port forwarding, no compose. Just `devcontainer.json` + thin `Dockerfile`.
   - `.devcontainer-postgres/` — **full**. Docker Compose with app + PostgreSQL, port forwarding, entrypoint that auto-starts `npm run dev`.

## Commands

```bash
./build.sh                                # Build/rebuild the base image
./devcontainer-rebuild.sh ~/repos/foo     # Teardown + relaunch a project's containers
./seed-ssh-key.sh                         # One-time: copy ~/.ssh into the shared 'persist' volume
./migrate-volumes.sh list                 # Show which Claude/Codex/persist volumes exist
./migrate-volumes.sh backup ~/dc-backup   # Back up those volumes (for moving to another machine)
./migrate-volumes.sh restore ~/dc-backup  # Restore them on the new machine (before ./build.sh)
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
- Named volumes persist across container rebuilds; the `:U` suffix maps ownership for rootless Podman. Per-project (compose-namespaced) volumes: `claude-config` (`~/.claude`), `codex-config` (`~/.codex`), `shell-history`, `npm-cache`, `playwright-cache`. One **shared, cross-project** volume: `persist` (`/home/node/persist`), declared `external` in the compose templates so every project sees the same files — create it once with `podman volume create persist` (`devcontainer-rebuild.sh` does this for you). Note: bun/pnpm/cargo/sccache caches do **not** use per-project volumes — they route onto `persist/cache/` for cross-project dedup (see [Worktrees & cross-project references](#worktrees--cross-project-references)); only npm itself uses the `npm-cache` volume.
- **Codex** is installed in the base image via the native standalone installer (`chatgpt.com/codex/install.sh`), replacing the old `npm i -g @openai/codex`. The binary + bundled `rg`/`bwrap` live in the image at `/home/node/.codex-dist` (build-time `CODEX_HOME`), so they update on image rebuilds and are never shadowed by a volume; at runtime `CODEX_HOME=/home/node/.codex` (the `codex-config` volume) holds only `auth.json`/`config.toml`, so logins persist. The launcher is the symlink `~/.local/bin/codex`.

### Where state lives (persistence model)

- `/workspace` — your project code (bind mount to the host repo; version-controlled). Survives everything.
- `/home/node/persist` — **shared** cross-project scratch (notes, tools, downloads) on the `persist` volume. Survives rebuilds and is visible in every container. This is the right home for personal/persistent files you'd otherwise scatter loosely in `/home/node`. Also holds `worktrees/`, `clones/`, and `cache/` (toolchain caches) — see [Worktrees & cross-project references](#worktrees--cross-project-references).
- `/home/node/repos` — **read-only** bind mount of the host's `~/repos`, so every project's live working tree is visible from every container (for reference/grep/build, and as the source for `refclone`). Zero extra disk; reflects the host, including uncommitted changes.
- `~/.claude`, `~/.codex` — per-project config volumes (auth, history, settings). Survive rebuilds.
- `~/.ssh` — a symlink to `/home/node/persist/.ssh`; seed it once with `./seed-ssh-key.sh`. The encrypted key rides the shared `persist` volume. We deliberately avoid bind-mounting `~/.ssh`: under enforcing SELinux that would relabel `authorized_keys` and can lock `sshd` out on the host. The shared ssh-agent ([Shell defaults](#shell-defaults-baked-into-the-image)) unlocks the key into a container-local agent process — the *decrypted* key lives only in that process's memory, never on the `persist` volume; only the agent's rendezvous socket (`~/.ssh/agent.sock`) sits there.
- `/tmp` — bind to the host's `/tmp/<project>`; survives rebuilds but is cleared on host reboot.
- **Anything else under `/home/node` (loose files, `~/tmp`, etc.) lives only in the container layer and is LOST on rebuild.** Put it in `/home/node/persist` instead.

### Worktrees & cross-project references

Everything here lives on one btrfs filesystem (host repos, `/home/node`, and the Podman named volumes all share a single subvolume — confirmed by identical `st_dev`), so files can be **reflinked** (copy-on-write) between any of them. Reflinks are as space-efficient as hardlinks but COW-safe (editing a file in one place never corrupts the source) and work across btrfs subvolumes, so the helpers below lean on them instead of hardlinks.

- **Worktrees** — run `wt <branch> [base-ref]` from inside a project. It creates a git worktree at `/home/node/persist/worktrees/<project>/<branch>` and reflink-clones `node_modules`/`target`/etc. from the main checkout, so a new worktree is near-instant and costs almost no disk until files diverge. The interactive `wt` cds into it; the underlying `/usr/local/bin/wt` script (usable from the Bash tool) just prints the path.
  - **Caveat:** a linked worktree's git metadata points at *this* container's `/workspace`, so it only works from the container that created it. Don't open a worktree from another project's container — use `refclone` for that.
- **Cross-project reference (read-only)** — every host project is mounted read-only at `/home/node/repos/<project>`. Grep, read, or build against another project with zero extra disk and no clone. (This relabels the host `~/repos` tree `shared` for SELinux on first start; if that's slow with large `node_modules`/`target` trees, narrow or drop the mount in the template.)
- **Cross-project writable copy** — `refclone <project> [dest-name]` makes a self-contained, reflinked copy of another project at `/home/node/persist/clones/<name>` (its own `.git`, so it works in any container). This replaces ad-hoc `git clone`s, which duplicated full history and deps; the reflinked copy is near-zero disk until changed. Caveat for **pnpm** projects cloned from the read-only `repos` mount: their `node_modules` symlinks point at the *host's* pnpm store, so they dangle in the copy — `refclone` warns and you re-run `pnpm install` (npm/yarn deps and clones of container projects are unaffected).

Toolchain caches route onto `persist` so they survive rebuilds and dedupe across projects: pnpm store (`store-dir` + `package-import-method=clone-or-copy` in `~/.npmrc`), bun (`BUN_INSTALL_CACHE_DIR`), sccache (`SCCACHE_DIR`), and cargo's registry/git (symlinked from `~/.cargo`, leaving its image-baked `bin/` intact) all live under `/home/node/persist/cache/`. `~/.zshenv` creates these dirs at shell start (the `persist` volume is absent at image-build time).

Optional btrfs tuning: `chattr +c` on a worktree/clone dir enables zstd compression (big win on `node_modules`/`target`); for the Postgres template, `chattr +C` (nodatacow) on the `postgres-data` dir before `initdb` avoids CoW fragmentation.

### Rebuild chain

Changes propagate in order: `init-firewall.sh` or `Dockerfile` → `./build.sh` (rebuilds base image) → `./devcontainer-rebuild.sh ~/repos/<project>` (rebuilds each downstream project container). Changes to `.devcontainer/` template files only need copying into the target project and rebuilding that project's container.

### Container lifecycle

The container runs as user `node` (non-root). The firewall and `fw-install` scripts are the only commands granted passwordless sudo (via `/etc/sudoers.d/node-firewall`).

**Minimal template:** `postStartCommand` runs the firewall on every start. No other lifecycle hooks.

**Postgres template:** lifecycle hooks run in order:
1. `postCreateCommand` (`npm install`) — runs once on first container create
2. `postStartCommand` (`sudo /usr/local/bin/init-firewall.sh`) — runs on every start
3. `container-entrypoint.sh` — the container's main `command`, waits for npm install then starts dev servers

### Shell defaults baked into the image

These are baked into the base image (in the `Dockerfile`), so they survive rebuilds and never need recreating inside a running container:

- **Shared ssh-agent.** `ssh-agent-init.sh` is copied to `/usr/local/bin/` and sourced from the image's `~/.zshenv`. Because zsh sources `~/.zshenv` for *every* invocation — interactive `podman exec` shells **and** Claude Code's non-interactive Bash tool — all of them rendezvous on one agent at the fixed socket `~/.ssh/agent.sock` instead of each spawning a throwaway agent on a random path. The script (re)starts an agent only when none is listening (`ssh-add -l` exit 2 ⇒ stale socket, replace it). Interactive shells with a tty prompt once to unlock `~/.ssh/id_ed25519` if it exists; the non-interactive Bash tool skips the prompt and never blocks. `ssh_config_github.conf` is baked to `/etc/ssh/ssh_config.d/10-devcontainer.conf` (`AddKeysToAgent`/`IdentitiesOnly` for `github.com`); a seeded `~/.ssh/config` is read first and still wins. The socket sits on the shared `persist` volume, so concurrently-running project containers can reach the same agent; the restart logic self-heals a socket left behind by a stopped container.
- **Agent aliases.** `~/.zshrc` (interactive shells only) aliases `claude` → `claude --dangerously-skip-permissions` and `codex` → `codex --yolo`. These apply only when you type the command interactively; the Bash tool runs non-interactively, so it is unaffected.
- **Worktree / clone helpers + cache routing.** `wt` and `refclone` are baked to `/usr/local/bin` (usable from the non-interactive Bash tool), with interactive zsh wrappers in `~/.zshrc` that `cd` into the result. `~/.zshenv` ensures the `persist` cache/worktree dirs exist and the image routes pnpm/bun/sccache/cargo caches onto `persist`. See [Worktrees & cross-project references](#worktrees--cross-project-references).
- **rust-analyzer caps.** `rust-analyzer.toml` is copied to `~/.config/rust-analyzer/rust-analyzer.toml`, rust-analyzer's user-global config (keys drop the `rust-analyzer.` prefix). It disables `cachePriming` (no upfront whole-workspace indexing spike), caps `numThreads = 4` (host has 8 logical cores), and lowers `lru.capacity = 64` (cached syntax trees, default 128) to keep memory in check across every Rust project.

### Template setup for new projects

**Minimal:** Copy `.devcontainer/` into the project. No further configuration needed.

**Postgres:** Copy `.devcontainer-postgres/` into the project as `.devcontainer/`, then `cp .env.example .env` and set `PROJECT_NAME`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`. The compose file uses `${PROJECT_NAME}` to namespace container names and volumes. The shared `persist` volume is `external`, so it must exist before launch — `devcontainer-rebuild.sh` runs `podman volume create persist` for you (or do it manually once).

To make your SSH key available in containers, run `./seed-ssh-key.sh` once on the host; it copies `~/.ssh` into the `persist` volume, which every container exposes at `~/.ssh`.

### Migrating to another machine

Claude/Codex state and the shared scratch live in Podman named volumes, not on the host filesystem. To move them: on the old machine `./migrate-volumes.sh backup ~/dc-backup`, copy `~/dc-backup` over, then on the new machine `./migrate-volumes.sh restore ~/dc-backup` **before** `./build.sh` and rebuilding each project. Volume names (including compose-namespaced ones like `musi_claude-config`) are preserved, so they line up as long as each project's `.env` `PROJECT_NAME` matches. The backup contains auth tokens and your encrypted SSH key — keep it private.

### Self-hosted tailnet services (Forgejo + Dolt)

Two self-hosted services run on the `devbox` host as **rootless podman + Quadlet units (systemd `--user`, linger)** — separate from the devcontainers, reachable by them over the Tailscale tailnet. They are **not yet deployed**; the directories are paste-ready realizations of their design docs.

- **`forgejo/`** — self-hosted Forgejo git server + local CI runner + nightly off-node backup. Forgejo is origin with a one-way push mirror to GitHub. Design/rationale + rev changelog in `forgejo-setup-plan.md`; deploy guide in `forgejo/README.md`. (`forgejo/` may be untracked — commit it before relying on it.)
- **`dolt/`** — a Dolt SQL server used as the shared **beads** (`bd`) issue store, synced via the remotesapi port. Self-contained design + deploy guide in `dolt/README.md`.
- **Firewall tie-in:** the dev containers reach these over the tailnet, so `init-firewall.sh` carries a **single unified allow-block** for tcp `3000`/`2222` (Forgejo http/ssh) + `50051` (Dolt remotesapi) to the devbox tailscale IP, gated on the host resolving into the `100.64.0.0/10` range. Don't add a second per-service rule — extend the existing block. The CI **runner** container has no egress firewall (it's a plain Quadlet container, not a devcontainer).

## Firewall domain management

To allow a new domain, add it to `REQUIRED_DOMAINS` or `OPTIONAL_DOMAINS` in `init-firewall.sh`, then rebuild the base image. `REQUIRED_DOMAINS` failures abort container startup; `OPTIONAL_DOMAINS` failures only log warnings. (The unified devbox tailnet allow-block for Forgejo/Dolt is separate — see [Self-hosted tailnet services](#self-hosted-tailnet-services-forgejo--dolt).)

To temporarily install apt packages without permanently modifying the base image:
```bash
sudo fw-install poppler-utils    # from inside the container
```
This opens the firewall, runs `apt-get install`, then restores the firewall. Packages installed this way do not persist across container rebuilds.
