# Dolt shared remote on devbox (beads issue store)

A long-lived **Dolt SQL server** on the `devbox` host that acts as the shared **beads
(`bd`) issue store** for the fleet of devcontainers. Each container keeps its own local,
embedded beads database and syncs to this central server with `bd dolt push` / `bd dolt
pull`. This directory holds everything needed to deploy it; the unit files next to this
README are paste-ready.

> **Status:** **deployed on devbox 2026-06-20**, image pinned to `dolthub/dolt-sql-server:2.1.8`.
> Server + auth + grants + clone/push round-trip verified from the host (see [§5](#5-verify-from-an-enforcing-devcontainer));
> end-to-end verification from inside a *running enforcing* container was deferred (the
> firewall rule is already baked into `init-firewall.sh`, so it lands on the next container
> rebuild). `musi` is created and left pristine, awaiting the first real `bd` client seed.

---

## 1. What this is (the concepts)

If "beads" and "Dolt" mean nothing to you, read this; otherwise skip to [§4](#4-deploy-on-devbox).

- **beads (`bd`)** is a CLI issue tracker for AI agents. It stores its issues in a
  **Dolt** database rather than flat files.
- **Dolt** is a version-controlled SQL database — "Git for data". It has its own commits,
  branches, and **remotes**, entirely separate from Git. A Dolt *remote* is a place you
  `push`/`pull` Dolt history to/from, exactly like a Git remote.
- Each beads client keeps a **local, in-process (embedded) Dolt database** and
  synchronizes with a shared remote over Dolt's native **remotesapi** protocol.
- This server is that shared remote.

**Why self-hosted.** The client fleet is many ephemeral containers, across multiple
machines, each using Git worktrees. The beads DB is per-worktree and containers are
ephemeral, so the shared source of truth must live *outside* any single container — and we
want one issue graph reachable by all of them. A self-hosted Dolt server speaking the
native remotesapi protocol gives that. (Rejected alternatives: committing issue data into
the product git repo ties issues to branches and causes per-branch churn/merge conflicts;
using GitHub as a Dolt remote over `git+ssh` mixes binary Dolt data into the product repo
and is slower than the native protocol.)

---

## 2. Architecture

```
                      devbox host
        ┌───────────────────────────────────────┐
        │  beads-dolt  (Quadlet, systemd --user) │
        │   • :50051  remotesapi (push/pull)     │ → tailscale IP, tailnet-reachable
        │   • :3306   MySQL protocol (admin)     │ → 127.0.0.1 only
        │   • volume  /var/lib/dolt              │
        │   • database: musi                     │
        └──────────────▲────────────────────────┘
                        │  http://devbox.tail76c33c.ts.net:50051/musi
       ┌────────────────┼─────────────────┬───────────────┐
       │                │                 │               │
 ┌─────┴─────┐    ┌─────┴─────┐     ┌─────┴─────┐   ┌─────┴─────┐
 │ container │    │ container │     │ container │   │  (other   │
 │  worktreeA│    │  worktreeB│     │  on host2 │   │  machines)│
 │  local DB │    │  local DB │     │  local DB │   │           │
 └───────────┘    └───────────┘     └───────────┘   └───────────┘
   each runs `bd dolt pull` at session start, `bd dolt push` at session close
```

**Two ports, two purposes:**

- **`:50051` — remotesapi.** The native Dolt remote protocol that `bd dolt push/pull`
  uses. **This is the one that matters.** Published on the **tailscale IP**
  (`100.65.243.16`) so every container on the tailnet reaches it.
- **`:3306` — MySQL protocol.** Used here only for **admin/setup** (creating the database
  and sync user). Published on **loopback only** (`127.0.0.1`), so it's reachable from
  devbox itself but never over the tailnet.

**Usage mode: push/pull only.** Clients keep a local DB and sync via remotesapi. This is
offline-friendly and has no single point of failure during work (eventually consistent at
sync points). A live "server mode" where clients connect their beads directly to `:3306`
for real-time shared state is *possible* but not enabled — if it's ever needed, move the
`:3306` publish to the tailscale IP deliberately; no other server-side change is required.

**Decided parameters** (don't re-litigate these):

| | |
|---|---|
| Database name | `musi` |
| Transport | plain `http` over the Tailscale tailnet (already WireGuard-encrypted); no TLS |
| Host address | MagicDNS name `devbox.tail76c33c.ts.net` (one URL works from every container on every machine) |
| devbox tailscale IP | `100.65.243.16` (the units bind this directly) |
| Client remote URL | `http://devbox.tail76c33c.ts.net:50051/musi` |
| Sync user | `beads` |

These mirror the Forgejo deployment's choices.

---

## 3. What's in this directory

| File | Role |
|---|---|
| `dolt.container` | Quadlet unit for `dolthub/dolt-sql-server`. Publishes `:50051` on the tailscale IP and `:3306` on loopback; boot-starts via `[Install]` + linger. |
| `dolt.volume` | Quadlet volume `dolt-data` → `/var/lib/dolt` (the database; the source of truth). |
| `dolt.network` | Quadlet network `dolt`. |
| `servercfg.d/config.yaml` | Server config; the `remotesapi` block is what turns on `:50051`. Mounted read-only into the container straight from this dir. |
| `dolt-update.sh` | Version-bump the pinned image with a pre-update volume snapshot + health gate (see [§8 Updating](#updating)). |
| `.env.example` | Copy to `.env` (gitignored) and set the root password. |

The environment is **rootless podman + Quadlet + systemd `--user` (linger), no host
sudo** — the same as the Forgejo deployment. The `[Install]` + linger setup is what makes
the service survive a host reboot (a bare `podman run` or compose would not).

---

## 4. Deploy on devbox

### 4.1 Prerequisites

- Rootless podman with the systemd `--user` generator (Quadlet), and **linger enabled** for
  the user (`loginctl enable-linger $USER`) so units start at boot without a login session.
- Network reachability decided — already done (tailnet + MagicDNS, see [§2](#2-architecture)).

### 4.2 Install the Quadlet units

```bash
# Copy the three unit files into the user's Quadlet dir. servercfg.d is NOT copied —
# dolt.container mounts it read-only straight from this repo dir.
cp ~/repos/devcontainer-base/dolt/dolt.network \
   ~/repos/devcontainer-base/dolt/dolt.volume \
   ~/repos/devcontainer-base/dolt/dolt.container ~/.config/containers/systemd/

# Create the env file with the root password BEFORE starting (see warning below).
cd ~/repos/devcontainer-base/dolt && cp .env.example .env && $EDITOR .env

systemctl --user daemon-reload
systemctl --user start dolt.service
```

> ⚠️ **Create `.env` before `start`.** `dolt.container` has `EnvironmentFile=…/.env` with
> no `-` prefix, so the file is **required**. Starting the unit without it fails with an
> opaque `EnvironmentFile … No such file` error rather than a clear "set the password"
> message.

Watch it come up:

```bash
systemctl --user status dolt.service
podman logs beads-dolt | grep -iE 'remotesapi|listening|3306|50051'
```

### 4.3 Create the database + sync user

`:3306` is published on loopback only, so do admin from **devbox itself** via `127.0.0.1`.
Connect as `root` (password = `DOLT_ROOT_PASSWORD` from `.env`):

```bash
# from devbox, if a mysql/mariadb client is installed:
mysql -h 127.0.0.1 -P 3306 -u root -p

# or a throwaway client container sharing the server's network namespace:
podman run --rm -it --network container:beads-dolt docker.io/library/mysql:8 \
  mysql -h 127.0.0.1 -P 3306 -u root -p
```

Then run:

```sql
-- the shared issues database
CREATE DATABASE IF NOT EXISTS musi;

-- a dedicated, non-root user the clients authenticate as
CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '<long-random-sync-password>';

-- Dolt push over remotesapi requires SUPER-USER-level privileges. CONFIRMED on Dolt
-- 2.1.8: a DB-scoped grant (ON musi.*) is NOT enough — push fails with
-- "API Authorization Failure: beads has not been granted SuperUser access". The global
-- grant below is therefore required, not optional, on this version.
GRANT ALL PRIVILEGES ON *.* TO 'beads'@'%' WITH GRANT OPTION;

-- Clone/fetch/pull over remotesapi additionally need the *dynamic* CLONE_ADMIN
-- privilege, which is NOT included in GRANT ALL PRIVILEGES (dynamic privileges must be
-- granted by name). Without it the first `bd dolt pull` / clone fails before any chunk
-- transfer is even reached.
GRANT CLONE_ADMIN ON *.* TO 'beads'@'%';
FLUSH PRIVILEGES;
```

> **Stop here — do not create a Dolt commit on the server.** A fresh Dolt database shares
> the deterministic "Initialize data repository" root commit, so a client whose history
> descends from that same root fast-forwards cleanly on its first push. Adding a
> server-side `DOLT_COMMIT` (even `--allow-empty`) puts a commit on the remote that no
> client has, turning the first `bd dolt push` into a divergent (non-fast-forward)
> rejection. The remote's real history is seeded **once, by the first client** — see
> [§5](#5-verify-from-an-enforcing-devcontainer) (which both seeds and verifies) and §9.
> The push/pull round-trip in §5 is the source of truth for whether this works on your
> Dolt version. **CONFIRMED on Dolt 2.1.8: the first push IS rejected as divergent**
> (`unknown push error; no common ancestor`) because `CREATE DATABASE musi` already seeds a
> `main` branch whose init commit doesn't match a fresh client's. So the first real seed
> needs a one-time `bd dolt push --force` (or clone-first), then never force again.

> The `*.*` grant above is the confirmed-required level for push on Dolt 2.1.8 (a scoped
> `musi.*` grant is rejected — see the comment in the SQL). Note that even `ALL PRIVILEGES
> ON *.*` does **not** include the dynamic `CLONE_ADMIN` granted separately above — keep
> that explicit grant no matter how wide you go. (The blast radius of `*.*` is bounded by
> network isolation: this server is dedicated to the beads store and is tailnet-only /
> loopback-admin — see [§6](#6-security).)

Deliver the sync password to clients **out-of-band**, never in a committed file.

### 4.4 Firewall

The dev containers run a **default-DROP egress firewall**, so `:50051` would be dropped
from any *enforcing* container. This is **already handled** in the base
`init-firewall.sh`: a single unified block allows tcp `3000`/`2222` (Forgejo) + `50051`
(Dolt remotesapi) to the devbox tailscale IP, gated on the host resolving into the
`100.64.0.0/10` tailnet range. **Do not add a second per-service rule** — extend that
existing block if anything ever changes.

The baked rule lands for every container at the next base rebuild (`./build.sh` → projects
re-pull the base). To open an **already-running** enforcing container immediately, with
zero restart:

```bash
for p in 3000 2222 50051; do
  podman exec -u root ma-toki iptables -I OUTPUT 1 -p tcp -d 100.65.243.16 --dport "$p" -j ACCEPT
done
```

(A non-enforcing container — one whose firewall is intentionally policy-ACCEPT — needs
nothing. A live rule like the above is wiped if the container restarts before the baked
script is updated.)

---

## 5. Verify (from an *enforcing* devcontainer)

This both **seeds** the remote (its first real history) and **verifies** it — exercising
auth, network reachability, the push grants, **and** the chunk transfer that local tests
miss. A clone alone is **not** sufficient: it only proves `CLONE_ADMIN` + reachability, not
the broad push path `bd dolt push` actually uses. Do the full round-trip, in order.

**Run from inside enforcing devcontainers (e.g. `ma-toki`), not a throwaway `dolt`
container.** A bare `dolthub/dolt:latest` container has no firewall, so it would pass even
when real clients are blocked — a false positive. After the firewall is open ([§4.4](#44-firewall)):

```bash
# 1) SEED + push test — from the first enforcing container, as the real client.
#    This establishes the remote's history (see the §4.3 note on why the server
#    must NOT pre-create a commit).
export DOLT_REMOTE_USER=beads DOLT_REMOTE_PASSWORD='<sync-pw>'
bd dolt remote add origin http://devbox.tail76c33c.ts.net:50051/musi
bd dolt push && echo "PUSH OK"

# 2) Re-clone test — from a *second* enforcing container, raw dolt so it exercises
#    chunk transfer independently of beads. Use the exact MagicDNS host, not localhost.
export DOLT_REMOTE_USER=beads DOLT_REMOTE_PASSWORD='<sync-pw>'
dolt clone --user beads http://devbox.tail76c33c.ts.net:50051/musi /tmp/musi-test \
  && echo "CLONE OK" && ls /tmp/musi-test   # confirm the pushed data is present
```

If clone metadata succeeds but data transfer hangs, that's the host-reachability gotcha in
[§8](#8-operational-notes--gotchas). If the push is rejected as divergent, see the §4.3
note (one-time `bd dolt push --force`, then never force again).

Once the round-trip passes, **pin the image tag** in `dolt.container` (replace `:latest`
with the exact tag) so the storage/protocol format can't drift under the in-process Dolt
bundled in `bd`. See [§8](#8-operational-notes--gotchas) on version compatibility.

---

## 6. Security

- **Strong, unique passwords** for both `root` and the `beads` sync user; keep them in
  `.env` / a secret store, never in committed files.
- **Network isolation is the primary access control.** `:50051` is on the tailnet only and
  `:3306` is loopback only. Treat tailnet reachability as the access boundary. Plain
  `http://` is acceptable **only** because the tailnet is already WireGuard-encrypted; if
  traffic ever has to cross anything untrusted, front remotesapi with a TLS reverse proxy
  (clients then use `https://…`) or configure Dolt's TLS options.
- **Least privilege:** the `beads` user has rights on the `musi` DB only (plus the dynamic
  `CLONE_ADMIN`); widen to `*.*` only if push truly requires it. Never hand clients the
  `root` password.
- **Never bind `0.0.0.0`.** The units bind the tailscale IP / loopback explicitly to keep
  the server off the home LAN (same rule as Forgejo).

---

## 7. Backups — REQUIRED follow-up

⚠️ **Nothing backs up the Dolt data by default, and the Forgejo nightly job does NOT cover
it.** The beads issue graph is the whole point of this service, and the `dolt-data` volume
is the **only** copy of its history. Until a backup is wired up, a lost volume means a lost
issue graph. This is a follow-up to implement, not optional hygiene.

Wire the Dolt data into the same nightly off-node routine as Forgejo
(`../forgejo/forgejo-backup.sh` is the pattern to mirror — dump → off-node `rsync` to
aura-farming). Pick one:

- **Logical (preferred):** `podman exec beads-dolt dolt backup …` / `CALL DOLT_BACKUP(...)`,
  or `dolt dump`, then rsync the artifact off-node. Survives storage-format quirks better
  than a raw volume copy.
- **Volume snapshot:** rsync the `dolt-data` volume mountpoint (stop the server or snapshot
  first for a consistent copy).

Dolt keeps full history, so the volume grows over time — monitor it.

---

## 8. Operational notes & gotchas

### Updating

`dolt.container` **pins an exact image tag** (unlike Forgejo's moving `:15`), so an update is a
deliberate version bump. `dolt-update.sh` scripts it with a pre-update snapshot + health gate:

```bash
./dolt/dolt-update.sh --check       # show pinned vs running version, then exit
./dolt/dolt-update.sh 2.2.5         # pin :2.2.5: pull, stop+snapshot, rewrite tag, restart, verify
```

It pulls the target tag (failing early if it doesn't exist), **stops the service and snapshots the
`dolt` volume** to `~/service-backups/dolt` (consistent — Dolt's chunk store can be mid-write;
override `SNAPSHOT_DIR`/`KEEP`, or `--no-backup` to skip), rewrites the `Image=` tag in
`dolt.container`, re-applies the unit to `~/.config`, restarts, and health-checks (container running
+ SQL `:3306` and remotesapi `:50051` accepting connections). **The tag rewrite is a real source
change — commit `dolt.container` afterward.** A failed health check prints exact rollback commands.

- **Privileges: push is broad, read needs `CLONE_ADMIN`.** Dolt's remotesapi push wants a
  super-user-ish grant; clone/fetch/pull need the dynamic `CLONE_ADMIN` privilege, which
  `GRANT ALL PRIVILEGES` does **not** cover. Both are granted in [§4.3](#43-create-the-database--sync-user).
- **Seed via the first client push, not a server commit.** The first `bd dolt push` seeds
  the remote's history ([§5](#5-verify-from-an-enforcing-devcontainer)). Do *not* pre-commit
  on the server — that creates a divergent root the first push can't fast-forward onto
  ([§4.3](#43-create-the-database--sync-user)). A clone attempted *before* anything is pushed
  fails with "remote has no branches" — expected; seed first.
- **Host reachability / advertised host.** Verify from a *remote* client using the real
  MagicDNS name, not localhost. Don't hand out an address that only works from inside the
  server.
- **Dolt version compatibility.** The clients embed Dolt *in-process* inside the `bd`
  binary; there is no separate client `dolt` binary whose version you can read, so treat the
  **push/pull round-trip test ([§5](#5-verify-from-an-enforcing-devcontainer)) as the source of truth.** Start on a recent
  `dolthub/dolt-sql-server` tag; if you hit a protocol/storage-format mismatch, pin the
  image to a version near the client's bundled Dolt and re-test. Once it works, **pin the
  tag** (don't float `:latest`) so it doesn't drift.
- **Volume ownership.** `dolt.container` mounts the data volume with `:U`
  (`Volume=dolt-data.volume:/var/lib/dolt:U`), which maps ownership to the container's
  run-user under rootless podman so the first write to `/var/lib/dolt` can't fail on a UID
  mismatch. If `dolt.service` *still* fails with a permission error writing there, check the
  image's run-user/entrypoint and inspect `podman logs beads-dolt`.
- **Boot race (handled in the unit).** Under a systemd `--user` manager, `After=network-online.target`
  is effectively a no-op (the user session doesn't pull that target), so at boot the manager
  can start `dolt.service` before `tailscale0` has its IP and the `100.65.243.16` bind
  fails. `dolt.container` handles this with `StartLimitIntervalSec=0` + `Restart=always` /
  `RestartSec=10`, which retries until the IP appears instead of hitting the default
  5-in-10s start limit and giving up. Don't remove those thinking `After=` covers it.
- **Restarts survive reboots.** `Restart=always` + `[Install] WantedBy=default.target` +
  linger keep it alive across reboots; confirm it comes back and clients reconnect after a
  host reboot.
- **Availability.** Both Forgejo and Dolt live on devbox, so when devbox sleeps,
  aura-farming loses both. Unlike Forgejo, beads push/pull is **offline-tolerant**: clients
  keep a local DB and just defer sync until devbox is back, so this degrades gracefully.

---

## 9. Client setup (the `musi` side) — the contract

You don't run these on the server; they're here so you know what the connection values are
for and can sanity-check them. The first client seeds the remote, the rest pull — that
initial seed is the same `bd dolt push` exercised in [§5](#5-verify-from-an-enforcing-devcontainer);
if it's rejected as divergent, see the §4.3 note (one-time `--force`).

```bash
# point the beads remote at the native server (replacing any temporary git remote)
bd dolt remote remove origin   # if a placeholder remote exists
bd dolt remote add origin http://devbox.tail76c33c.ts.net:50051/musi

# credentials (per container; from env / secret store)
export DOLT_REMOTE_USER=beads
export DOLT_REMOTE_PASSWORD='<sync-password>'

# first client seeds the remote, others pull
bd dolt push                 # initial population
bd dolt pull && bd bootstrap # on a fresh container/worktree
```

Sync is then automated: `bd dolt pull` at session start, `bd dolt push` at session close.

---

## 10. Connection details to hand back

Once verified, the connection block (deliver the password out-of-band, not in the repo):

```
BEADS DOLT REMOTE — connection details
  scheme:          http        (tailnet is WireGuard-encrypted; no TLS)
  host:            devbox.tail76c33c.ts.net
  remotesapi port: 50051
  sql port:        3306        (loopback-only, admin)
  database:        musi
  sync user:       beads
  sync password:   <delivered out-of-band>
  remote URL:      http://devbox.tail76c33c.ts.net:50051/musi
  verified:        yes/no      (round-trip from an enforcing container succeeded?)
  image tag:       docker.io/dolthub/dolt-sql-server:<pinned-tag>
```

---

## References

- Dolt — Using Remotes: <https://www.dolthub.com/docs/sql-reference/version-control/remotes>
- Dolt SQL Server Push Support (self-hosted remotesapi, auth):
  <https://www.dolthub.com/blog/2023-12-29-sql-server-push-support/>
- `dolthub/dolt-sql-server` Docker image: <https://hub.docker.com/r/dolthub/dolt-sql-server>
- Beads: <https://github.com/gastownhall/beads>
</content>
</invoke>
