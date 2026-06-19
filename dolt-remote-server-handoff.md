# Beads / Dolt Shared Remote — Server Setup Handoff

> **Audience:** an agent operating on the always-on server, with **no access to the
> conversation that produced this document**. Everything needed is here.
>
> **Your deliverable:** a long-lived, network-reachable Dolt service that multiple
> containers (on this machine and others) can use as a shared beads issue store,
> plus the connection values handed back so the client side can be wired up.
>
> **Status when you receive this:** the client side (the `musi` repo) already has
> beads installed and initialized with a *local* embedded database. It is currently
> pointed at a temporary git-based remote that we are replacing with the service you
> are about to stand up. Nothing has been pushed yet.

> ⚠️ **devbox realization (read this first).** This generic handoff has been reconciled to the
> actual target host, `devbox`, which runs **rootless podman + Quadlet + systemd `--user`
> (linger), no host sudo** — not Docker. The concrete, ready-to-deploy version of these
> instructions lives in **`dolt/README.md`** in the `devcontainer-base` repo, alongside
> installable Quadlet unit files (`dolt.container` / `.volume` / `.network`) and the
> `servercfg.d/config.yaml`. Two devbox-specific facts this generic doc doesn't capture:
> (1) the beads clients sit behind a **default-DROP container firewall**, so **tcp 50051 must
> be allowlisted** — already handled in `init-firewall.sh` (unified Forgejo+Dolt block);
> (2) verification must come from an **enforcing** devcontainer, not a throwaway `dolt`
> container (which has no firewall and gives a false pass). Use `dolt/README.md` for *how* to
> deploy on devbox; use the sections below for the Dolt/beads *concepts* and security detail.
> The §9 open questions are resolved (below and in the README).

---

## 0. TL;DR

Stand up a **`dolt sql-server`** (Docker: `dolthub/dolt-sql-server`) that exposes:

- **port 3306** — MySQL protocol (administration; also enables optional beads "server
  mode" later).
- **port 50051** — Dolt **remotesapi** (this is what `bd dolt push` / `bd dolt pull`
  use). This is the important one.

Create a database (`musi`) and a dedicated sync user with full privileges on it.
Make both ports reachable by the client containers over your private network (not the
public internet, unless you add TLS). Verify with a test `dolt clone` **from a second
container/host**. Then hand back the connection block in [§7](#7-what-to-hand-back).

---

## 1. Context (read this if "beads" / "Dolt" mean nothing to you)

- **musi** is a TypeScript monorepo (a virtual tabletop app). Irrelevant to your task
  except that its repo is where the *client* half of this setup lives.
- **beads (`bd`)** is a CLI issue tracker for AI agents. It stores issues in a
  **Dolt** database, not flat files.
- **Dolt** is a version-controlled SQL database — "Git for data". It has its own
  commits, branches, and **remotes**, entirely separate from Git. A Dolt *remote* is
  a place you `push`/`pull` Dolt history to/from, exactly like a Git remote.
- Each beads client keeps a **local, in-process (embedded) Dolt database** and
  synchronizes with a shared remote via `bd dolt push` / `bd dolt pull`.

### Why a self-hosted Dolt remote (the decision already made)

The client fleet is: **multiple ephemeral containers, across multiple machines, each
using Git worktrees.** Two facts forced this design:

1. The beads DB is **per-worktree** (each worktree gets its own embedded DB), and
   containers are **ephemeral** — so the shared source of truth must live *outside*
   any single agent container.
2. We want one shared issue graph reachable by all of them.

Rejected alternatives: committing issue data into the `musi` git repo (ties issues to
branches, causes per-branch churn/merge-conflicts, doesn't span worktrees); and using
the GitHub repo as a Dolt remote over `git+ssh` (works, but mixes binary Dolt data
into the product repo and is slower than the native protocol).

**Chosen:** a self-hosted Dolt server speaking the **native remotesapi protocol**,
which you are building.

---

## 2. End-state architecture

```
                 always-on server
        ┌───────────────────────────────────┐
        │  dolt-sql-server  (this task)      │
        │   • :3306   MySQL protocol         │
        │   • :50051  remotesapi (push/pull) │
        │   • volume  /var/lib/dolt          │
        │   • database: musi                 │
        └──────────────▲────────────────────┘
                        │  http(s)://HOST:50051/musi
       ┌────────────────┼─────────────────┬───────────────┐
       │                │                 │               │
 ┌─────┴─────┐    ┌─────┴─────┐     ┌─────┴─────┐   ┌─────┴─────┐
 │ container │    │ container │     │ container │   │  (other   │
 │  worktreeA│    │  worktreeB│     │  on host2 │   │  machines)│
 │  local DB │    │  local DB │     │  local DB │   │           │
 └───────────┘    └───────────┘     └───────────┘   └───────────┘
   each runs `bd dolt pull` at session start, `bd dolt push` at session close
```

**Two usage modes this one deployment supports** (clients choose; you set up both
ports regardless):

- **Push/pull (default, recommended):** clients keep a local DB and sync via
  remotesapi (`:50051`). Offline-friendly, no single point of failure during work,
  eventually consistent at sync points. **This is what we are using.**
- **Server mode (optional, future):** clients connect their beads directly to the
  live SQL server (`:3306`) for real-time shared state. More coupling and latency;
  enable only if real-time cross-agent visibility becomes necessary. No extra
  server-side work — the `:3306` listener you set up already supports it.

> It does not matter whether this runs as a **dedicated container** or **inside an
> existing long-running container** — the only requirements are that it is
> **long-lived** (survives agent containers) and **network-reachable** by every
> client. A dedicated container via the compose file below is the cleanest.

---

## 3. Your task — step by step

### 3.1 Prerequisites

- Docker (+ optionally docker compose) on the always-on server.
- A **persistent volume** for the database files.
- A networking decision (see [§3.5](#35-networking)).
- A secrets store / `.env` for passwords — **do not hardcode them in committed files.**

### 3.2 Config file

Create `./servercfg.d/config.yaml` (mounted read-only into the container). This is
what turns on the remotesapi port:

```yaml
# servercfg.d/config.yaml
log_level: info

listener:
  host: 0.0.0.0          # listen on all interfaces inside the container
  port: 3306
  max_connections: 128

# Enables the native Dolt remote protocol used by `bd dolt push`/`pull`.
remotesapi:
  port: 50051

# data dir is provided by the image at /var/lib/dolt (see volume below)
```

### 3.3 docker-compose (recommended)

```yaml
# docker-compose.yml
services:
  dolt:
    image: dolthub/dolt-sql-server:latest   # see §6 on version pinning
    container_name: beads-dolt
    restart: unless-stopped
    environment:
      DOLT_ROOT_PASSWORD: "${DOLT_ROOT_PASSWORD:?set DOLT_ROOT_PASSWORD in .env}"
      DOLT_ROOT_HOST: "%"                    # allow root from other hosts (admin)
    ports:
      - "3306:3306"      # MySQL protocol  (admin; optional beads server mode)
      - "50051:50051"    # remotesapi      (beads push/pull) — the important one
    volumes:
      - dolt-data:/var/lib/dolt             # persistent database storage
      - ./servercfg.d:/etc/dolt/servercfg.d:ro
volumes:
  dolt-data:
```

`.env` (not committed):

```
DOLT_ROOT_PASSWORD=<long-random-root-password>
```

Bring it up:

```bash
docker compose up -d
docker compose logs -f dolt        # watch it start; should bind :3306 and :50051
```

Equivalent `docker run` (if you prefer no compose):

```bash
docker run -d --name beads-dolt --restart unless-stopped \
  -e DOLT_ROOT_PASSWORD="$DOLT_ROOT_PASSWORD" \
  -e DOLT_ROOT_HOST='%' \
  -p 3306:3306 -p 50051:50051 \
  -v dolt-data:/var/lib/dolt \
  -v "$PWD/servercfg.d:/etc/dolt/servercfg.d:ro" \
  dolthub/dolt-sql-server:latest
```

### 3.4 Create the database + sync user

Connect to the running server with any MySQL-compatible client as `root`
(password = `DOLT_ROOT_PASSWORD`) and run:

```sql
-- the shared issues database
CREATE DATABASE IF NOT EXISTS musi;

-- a dedicated, non-root user the clients will authenticate as
CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '<long-random-sync-password>';

-- Dolt push over remotesapi requires broad privileges on the target DB.
GRANT ALL PRIVILEGES ON musi.* TO 'beads'@'%' WITH GRANT OPTION;

-- Clone/fetch/pull over remotesapi need the *dynamic* CLONE_ADMIN privilege, which
-- is NOT included in GRANT ALL PRIVILEGES (dynamic privileges must be granted by
-- name). Without it the first `bd dolt pull` / clone fails before any chunk
-- transfer is even reached.
GRANT CLONE_ADMIN ON *.* TO 'beads'@'%';
FLUSH PRIVILEGES;

-- Make an initial empty Dolt commit so a fresh `dolt clone` succeeds during
-- verification (a brand-new DB with zero commits cannot be cloned):
USE musi;
CALL DOLT_COMMIT('--allow-empty', '-m', 'init shared beads remote');
```

> If a later `bd dolt push` is rejected for privileges, widen to
> `GRANT ALL PRIVILEGES ON *.* TO 'beads'@'%' WITH GRANT OPTION;` — Dolt's push path
> effectively wants a super-user. Start scoped, widen only if needed. (Note: even
> `ALL PRIVILEGES ON *.*` does **not** include the dynamic `CLONE_ADMIN` granted
> above — keep that explicit grant no matter how wide you go.)

How to get a SQL prompt (pick one):

```bash
# from the host, if a mysql/mariadb client is installed:
mysql -h 127.0.0.1 -P 3306 -u root -p

# or a throwaway client container on the same docker network:
docker run --rm -it --network container:beads-dolt mysql:8 \
  mysql -h 127.0.0.1 -P 3306 -u root -p
```

### 3.5 Networking

- **Same-host containers:** put the client containers and `beads-dolt` on the same
  Docker network; clients then reach it at `http://beads-dolt:50051/musi`.
- **Cross-machine:** the clients need to reach `:50051` (and `:3306` if you use server
  mode) over your **private network** — e.g. Tailscale/WireGuard, or a LAN address.
  Prefer binding the published ports to the private interface rather than `0.0.0.0`,
  e.g. `- "100.x.y.z:50051:50051"`.
- **Do not expose remotesapi to the public internet over plain `http`** — it is
  unauthenticated at the transport layer and unencrypted. See [§4](#4-security).

---

## 4. Security

- **Strong, unique passwords** for both `root` and the `beads` sync user; store in a
  secret manager / `.env`, never in committed files.
- **Network isolation first.** Keep `:3306`/`:50051` on a trusted private network
  (VPN/overlay). Treat network reachability as the primary access control.
- **TLS** if traffic crosses anything untrusted: front the remotesapi with a TLS
  reverse proxy (then clients use `https://HOST:PORT/musi`) or configure Dolt's TLS
  options. Plain `http://` is fine **only** on a fully trusted network.
- **Least privilege:** the `beads` user gets rights on the `musi` DB only (widen to
  `*.*` only if push truly requires it). Don't hand clients the `root` password.
- **Backups:** see [§6](#6-gotchas--operational-notes).

---

## 5. Verification (do this before handing back)

1. **Server is up and listening:**
   ```bash
   docker compose ps
   docker compose logs dolt | grep -iE 'remotesapi|listening|3306|50051'
   ```
2. **SQL reachable:** connect as `root` over `:3306` (see §3.4) and `SHOW DATABASES;`
   lists `musi`.
3. **remotesapi round-trip from a *separate* container/host** — this is the real test
   (it exercises auth + reachability + the chunk transfer that local tests miss):
   ```bash
   docker run --rm -e DOLT_REMOTE_PASSWORD='<sync-password>' dolthub/dolt:latest \
     dolt clone --user beads http://<SERVER_HOST>:50051/musi /tmp/musi-test \
     && echo "CLONE OK"
   ```
   - Run this from a **different machine** (or at least a container that reaches the
     server only via the network), using the **exact host** clients will use — not
     `localhost`. If clone metadata succeeds but data transfer hangs, that's the
     host-reachability gotcha in [§6](#6-gotchas--operational-notes).
4. **Write round-trip (optional but ideal):** in the cloned copy, make a commit and
   `dolt push`, then re-clone elsewhere and confirm it's there.

---

## 6. Gotchas & operational notes

- **Client-side egress firewall (devbox).** The beads clients run inside devcontainers with a
  default-DROP egress firewall; **`:50051` to this server must be on the allowlist** or
  `bd dolt push/pull` is silently dropped. Handled in `devcontainer-base/init-firewall.sh`
  (unified Forgejo+Dolt block, tcp 3000/2222/50051). **Verify from an *enforcing* container**
  (e.g. ma-toki) — a bare `dolt` container has no firewall and will give a false pass. See
  `dolt/README.md` §1–§2.
- **Privileges: push is broad, read needs CLONE_ADMIN.** Dolt's remotesapi push
  wants a super-user-ish grant; clone/fetch/pull need the dynamic `CLONE_ADMIN`
  privilege, which `GRANT ALL PRIVILEGES` does **not** cover. Both are granted in
  §3.4. If push still fails on permissions, widen the DB grant (§3.4).
- **Empty DB can't be cloned.** Always make the initial `DOLT_COMMIT('--allow-empty')`
  (§3.4) or the first `dolt clone` fails with "remote has no branches".
- **Host reachability / advertised host.** Verify from a *remote* client using the
  real hostname, not localhost. Use a **stable DNS name or fixed private IP** that
  resolves identically for every client. Avoid handing out an address that only works
  from inside the server.
- **Dolt version compatibility.** The clients embed Dolt *in-process* inside the
  `bd` binary (beads `v1.0.5`); there is no separate client `dolt` binary to read a
  version from, so treat the **push/pull round-trip test (§5.3–5.4) as the source of
  truth**. Use a recent `dolthub/dolt-sql-server`. If you hit a protocol/storage-format
  mismatch, pin the image to a version near the client's bundled Dolt and re-test.
  Once it works, **pin the image tag** (don't float `:latest`) so it doesn't drift.
- **Backups.** The volume `dolt-data` is the source of truth. Back it up via volume
  snapshots, or logically with `dolt backup` / `dolt sql -q "CALL DOLT_BACKUP(...)"`,
  or a periodic `dolt dump`. Dolt keeps full history, so storage grows over time —
  monitor the volume.
- **Restarts.** `restart: unless-stopped` keeps it alive across reboots; confirm it
  comes back and clients reconnect after a host reboot.

---

## 7. What to hand back

Return this filled-in block (deliver the passwords over a secure channel, not in
plain text in the repo):

```
BEADS DOLT REMOTE — connection details
  scheme:          http   | https        (https if behind TLS)
  host:            <hostname-or-private-ip reachable by all clients>
  remotesapi port: 50051
  sql port:        3306
  database:        musi
  sync user:       beads
  sync password:   <delivered out-of-band>
  remote URL:      http://<host>:50051/musi
  verified:        yes/no  (test clone from a separate host succeeded?)
  image tag:       dolthub/dolt-sql-server:<pinned-tag>
```

---

## 8. What the client (musi) side will do with this — the contract

You don't need to run these; they're here so you understand what the values are for
and can sanity-check them.

```bash
# replace the temporary git remote with the native one
bd dolt remote remove origin
bd dolt remote add origin http://<host>:50051/musi

# credentials (per container; from env / secret store)
export DOLT_REMOTE_USER=beads
export DOLT_REMOTE_PASSWORD=<sync-password>

# first client seeds the remote, others pull
bd dolt push                 # initial population
bd dolt pull && bd bootstrap # on a fresh container/worktree
```

Sync is then automated: `bd dolt pull` at session start, `bd dolt push` at session
close.

---

## 9. Open questions — RESOLVED

1. **Database name** — `musi`. Confirmed.
2. **Transport** — plain `http` over the Tailscale tailnet (already WireGuard-encrypted); no
   TLS for now. Matches the Forgejo deployment's decision.
3. **Host/address** — MagicDNS name `devbox.tail76c33c.ts.net` (not a raw IP), so one URL works
   from every container on both laptops. Remote URL: `http://devbox.tail76c33c.ts.net:50051/musi`.
4. **Server mode (`:3306` live)** — no; push/pull only for now. The `:3306` listener is still
   set up (admin), but clients use remotesapi (`:50051`). Enable server mode later only if
   real-time cross-agent visibility becomes necessary.

---

## References

- Dolt — Using Remotes: <https://www.dolthub.com/docs/sql-reference/version-control/remotes>
- Dolt SQL Server Push Support (self-hosted remotesapi, auth):
  <https://www.dolthub.com/blog/2023-12-29-sql-server-push-support/>
- `dolthub/dolt-sql-server` Docker image: <https://hub.docker.com/r/dolthub/dolt-sql-server>
- Beads: <https://github.com/gastownhall/beads>
