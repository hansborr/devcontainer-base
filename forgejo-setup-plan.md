# Forgejo + local CI/CD setup plan (rev 6)

> Status: **READY TO IMPLEMENT — not yet deployed.** Rev 6 **materializes** this plan into paste-ready
> files under [`forgejo/`](forgejo/) (Quadlet units, runner image, backup job, deploy guide), with the
> rev-5 review items C1–C7 resolved. The §6.1 snippets below are now *design reference only* — the
> canonical, paste-ready source is the `forgejo/` directory; `forgejo/README.md` is the deploy guide.
> Rev 3 sequenced the rollout to be **non-disruptive** to the running devcontainers (verified on-host);
> rev 2 incorporated an external AI review.
> Author context: Claude Code, working in `~/repos/devcontainer-base` on host `devbox`.
> Date: 2026-06-19.

> **Disruption summary (read first):** Steps 1–4 (Forgejo, runner, backups) create only *new* isolated
> rootless containers and **do not restart or rebuild** the running musi/ma-toki containers. The only
> potentially disruptive part is the firewall change (§6.2); rev 3 splits it into a **zero-restart live apply
> now** + a **deferred bake-in at your next natural rebuild**, so nothing forces a `devcontainer-rebuild.sh`
> teardown. See §6.2 and §7.

## 0. Changelog from review (rev 1 → rev 2)

| # | Review finding | Resolution in rev 2 |
|---|---|---|
| 1 | `PublishPort 3000/2222` binds `0.0.0.0` → exposes plain HTTP on the home LAN, not just the tailnet | **Bind to the tailscale IP**: `PublishPort=100.65.243.16:3000:3000` / `…:2222:22`. `Restart=always` covers the boot race if `tailscale0` isn't up yet. |
| 2 | `start` doesn't enable services for boot | Boot-start comes from `[Install] WantedBy=default.target` + `daemon-reload` (Quadlet units **can't** be `systemctl enable`d — they're generator-created). `start` is only for the immediate run. Added a reboot acceptance test. |
| 3 | `:11` is old; current is v15, 15.0 LTS → Jul 2027 | Pin **`forgejo:15`** (LTS). Confirm latest LTS at implementation. |
| 4 | Host executor = jobs can read/mutate runner `/data` incl. registration | Documented plainly. Added `runner.capacity=1`, a per-job `timeout`, `host.workdir_parent=/data/work`, and an explicit "no persist/SSH mounts on the runner" rule. |
| 5 | Runner volume + `USER node` → not writable | `:U` on the runner data volume (and in the one-time register command). |
| 6 | `/32` in `allowed-domains` allows *all* ports to that IP | Replaced with **explicit OUTPUT rules for TCP 3000/2222 only**, after resolving the host and validating it's in `100.64.0.0/10`. |
| 7 | Runner `6.3.1` stale (current 12.x) | Copy the binary from the **official runner image** (`data.forgejo.org/forgejo/runner:<major>`) via multi-stage build; confirm current major + binary path. |
| 8 | "Failover" is wrong — mirror is one-way | Reworded to **backup mirror**; added a reconciliation note for the devbox-down-then-push-to-GitHub case. |
| D1 | Backups belong in phase one | New **§5.4**: nightly `forgejo dump` copied off-node to aura-farming. Removed from "future". |
| D2 | Remove `AutoUpdate=registry` until backups exist | Removed; manual update after a dump. |
| D3 | Unqualified `uses:` need an actions URL | Set `FORGEJO__actions__DEFAULT_ACTIONS_URL=https://data.forgejo.org`. |

### Changelog rev 2 → rev 3 (non-disruptive rollout)

Verified on-host with musi/ma-toki running (read-only probes):

| # | Finding | Resolution in rev 3 |
|---|---|---|
| R1 | **Only the base-image `init-firewall.sh` runs at runtime.** The `musi`/`ma-toki` `.devcontainer/init-firewall.sh` copies are vestigial — the thin project Dockerfiles don't COPY them; both live containers run the base-baked script (hash `d3a5224…` == base repo; the musi project copy is a stale, unused `e75c231…`). | §6.2 now edits **only** the base script. Editing project copies changes nothing (optional cleanup: delete the dead copies). The change propagates via `./build.sh` + re-pulling base into a project — i.e. only at a project rebuild. |
| R2 | `devcontainer-rebuild.sh` does a teardown+relaunch ⇒ disruptive; but the rule can be applied **live** with `podman exec -u root <ctr> iptables …` (works without host sudo or restart — verified). | §6.2/§7 split the firewall step: **5a** live-insert now (zero restart), **5b** bake into base later, riding the next natural rebuild. Live rule is ephemeral (wiped if the container restarts before 5b). |
| R3 | **musi's firewall is intentionally disabled by the user** (policy ACCEPT, `example.com` reachable). ma-toki's is enforcing. | No action for musi (by design): it already has open outbound and can reach Forgejo as-is. The baked rule (5b) still lands for whenever musi's firewall is re-enabled/rebuilt. Only **ma-toki** needs the live insert (5a). |
| R4 | Steps 1–4 don't touch running containers; host `:3000`/`:2222` free; `daemon-reload` doesn't restart anything; the runner builds FROM the existing base (no base rebuild in 1–4). | Captured in the §7 sequence and the disruption summary up top. |

### Changelog rev 3 → rev 4 (Dolt remote reconciliation)

Reconciled with the Beads/Dolt shared-remote plan (`dolt/README.md`) so the two plans
don't collide on the container firewall:

| # | Finding | Resolution in rev 4 |
|---|---|---|
| F1 | The Dolt beads remote needs **tcp 50051** reachable from the dev containers, but this plan's §6.2 block opened only 3000/2222 → `bd dolt push/pull` would be silently dropped from *enforcing* containers. | §6.2 firewall block **unified**: one allow-block for **3000/2222/50051** to the devbox tailscale IP, implemented + committed in `init-firewall.sh`. Do not add a separate Dolt rule. |
| F2 | Two services on devbox; firewall verification could false-pass from a no-firewall throwaway container. | Verify beads sync from an **enforcing** devcontainer (ma-toki), not a throwaway `dolt` container. See `dolt/README.md` (Firewall + Verify). |
| F3 | The Dolt remote was originally specced for Docker/compose; devbox is rootless podman + Quadlet, no host sudo. | Dolt ships as Quadlet units in `dolt/` (boot-start via linger, like Forgejo), not compose. |

### Changelog rev 4 → rev 5 (Codex design review)

A second-opinion review (OpenAI Codex, `gpt-5.5`, xhigh) cross-checked both plans and the
committed Dolt files against current upstream docs. The **Dolt** fixes were applied to
`dolt/`; the **Forgejo** items below are captured here for implementation time (Forgejo
is still unbuilt — none of these block the Dolt deploy):

| # | Finding | Action at implementation |
|---|---|---|
| C1 | Runner registration flow may be stale. Current Forgejo Runner expects `url`/`uuid`/`token` in its config file; the `forgejo-runner register --no-interactive --token` flow (§7.3) and the `config.yml` with no `server.connections` block (§6.1) may not match the runner major you pin. | **Verify the register + config schema against the exact `forgejo-runner` version** before relying on §7.3. |
| C2 | The runner container inherits **no egress firewall** — `init-firewall.sh` runs from the devcontainer `postStartCommand`, but the runner Quadlet just runs `forgejo-runner daemon`, so CI jobs get broader outbound than musi/ma-toki. | Accept + document, or add a deliberate firewall step to the runner. Compounds the host-executor trust caveat (§5.2). |
| C3 | Boot-race: units bind the tailscale IP but only set `Restart=always`. If the user manager starts before `tailscale0` has the IP, systemd burns the default 5-in-10s start limit and gives up. | Add `RestartSec=10` + `StartLimitIntervalSec=0` to the Forgejo and runner units (already applied to `dolt.container`). |
| C4 | `:U` is on the runner data volume but **not** `forgejo-data` (§6.1). | Add `:U` to `forgejo-data` before first write, or verify the image handles ownership (already applied to `dolt-data`). |
| C5 | The §6.1 unit snippets carry trailing inline comments (e.g. `VolumeName=forgejo-data # …`, Dockerfile trailing comments) that would corrupt the files if pasted literally. | Strip trailing inline comments when writing the real unit files. |
| C6 | The live-insert (§6.2 phase 5a) hardcodes `100.65.243.16`. | Re-confirm the tailscale IP before applying. |
| C7 | Title said "rev 3" while content was rev 4. | Title bumped to rev 5. |

> The Dolt **advertised-host** worry (earlier flagged as the top snag) was **downgraded** by the
> review: remotesapi listens on the same IP as the SQL server and only needs the `port` field,
> which `dolt/servercfg.d/config.yaml` already sets. Still verify it end-to-end with a real
> clone+push round-trip from an *enforcing* container at deploy.

### Changelog rev 5 → rev 6 (materialized into `forgejo/`)

The plan was materialized into a paste-ready [`forgejo/`](forgejo/) directory (parallel to `dolt/`),
and each rev-5 review item was resolved in the real files. Version-dependent facts were re-verified
against current upstream docs (Forgejo v15 LTS, runner v12) in June 2026; the tailscale IP was
re-confirmed on-host (`100.65.243.16`).

| # | rev-5 item | Resolution in rev 6 (canonical file) |
|---|---|---|
| C1 | Runner register/config schema may be stale. | **Verified.** Forgejo 15 deprecated `register`/`create-runner-file` in favor of config-declared `server.connections`, but `register` still works and `.runner` is supported going forward. `forgejo/runner/config.yml` ships the **secret-free `register` + `.runner` flow** (default; keeps secrets off the repo-mounted config), with the **config-declared flow documented as the future-proof alternative** in `forgejo/README.md`. Added `runner.file: /data/.runner`; confirmed flags (`--instance`/`--token`/`--labels`) and label syntax (`devcontainer:host`). |
| C2 | Runner inherits no egress firewall. | **Accepted + documented** in `forgejo/README.md` (Firewall): CI jobs get broader outbound than the dev containers; mitigated by never mounting `persist`/SSH/personal material into the runner. |
| C3 | Boot-race (tailscale IP not up at unit start). | **Fixed:** `StartLimitIntervalSec=0` + `RestartSec=10` added to **both** `forgejo.container` and `forgejo-runner.container` (matches `dolt.container`). |
| C4 | `:U` on runner data but not `forgejo-data`. | **Resolved deliberately:** `forgejo-data` omits `:U` (the image's root entrypoint chowns `/data` via `USER_UID`/`USER_GID`; `:U` would recursively re-chown the growing repo tree every start). `:U` kept on the small runner volume (runs as `USER node`, no chowning entrypoint). Rationale in `forgejo/README.md` (Ownership). |
| C5 | Trailing inline comments would corrupt pasted unit files. | **N/A now** — the real files in `forgejo/` use only full-line comments; nothing is pasted from the snippets below. |
| C6 | Live-insert hardcodes `100.65.243.16`. | **Re-confirmed** on-host at materialization time (`tailscale ip -4` + MagicDNS both → `100.65.243.16`). Unchanged. |
| C7 | Title said rev 3 while content was rev 4/5. | Title now rev 6, content matches. |
| — | Image/binary versions. | Confirmed: `codeberg.org/forgejo/forgejo:15` (LTS to 2027-07-15), `data.forgejo.org/forgejo/runner:12`, binary `/bin/forgejo-runner`. Set `FORGEJO__database__PATH=/data/gitea/forgejo.db` so the sqlite filename is deterministic. |

> The §6.1/§6.2/§7 snippets below are retained as design reference; **the canonical source is the
> `forgejo/` directory** — see `forgejo/README.md` for the deploy sequence and the resolved details.

## 1. Goal

Stand up a self-hosted **Forgejo** git server with **local CI/CD**, containerized (no native host install),
reachable from the **musi** and **ma-toki** dev containers on **both laptops** (`devbox`, `aura-farming`),
including when roaming on other networks — via the existing Tailscale tailnet.

## 2. Decisions (locked with the user)

| Axis | Decision |
|---|---|
| **Host node** | `devbox` (this laptop) is the primary/only Forgejo host. Accepted trade-off: when `devbox` is asleep/off, `aura-farming` loses Forgejo. |
| **CI scope** | Run **tests + lint** only. No image building → no dind / privileged runner. |
| **Access** | Plain **HTTP + SSH** over the tailnet only (no TLS — tailnet is already encrypted; ports bound to the tailscale IP, not the LAN). |
| **GitHub** | Forgejo is **origin**; one-way push **backup mirror** to GitHub per repo. |
| **DB** | **SQLite** + nightly `forgejo dump` off-node (phase one). Postgres out of scope. |

## 3. Facts verified on the live system

Probed read-only on `devbox`, musi/ma-toki running:

1. Tailnet up: `devbox`=`100.65.243.16`, `aura-farming`=`100.104.230.32`, tailnet `tail76c33c.ts.net`, MagicDNS on.
2. **MagicDNS resolves inside the dev containers** (`getent hosts devbox.tail76c33c.ts.net` → `100.65.243.16`).
   → one clean URL everywhere; no raw IPs in remotes. *(Confirm `dig` resolves the same at firewall-setup time — see §6.2.)*
3. Container → tailnet routing works (via `10.89.0.1` bridge → host → `tailscale0`).
4. **Hairpin works** — a container on devbox reached devbox's own tailscale IP. Same URL works on both laptops.
5. Container firewall blocks non-allowlisted tailnet ports (`:3000` refused). `:22` is already globally allowed.
6. **Boot persistence is free** — `loginctl show-user dev` → `Linger=yes`.
7. **Host firewalld needs NO change** — `tailscale0` is in *no zone* → default zone `FedoraWorkstation`, whose stock
   def includes `<port protocol="tcp" port="1025-65535"/>`. 3000/2222 ≥ 1025 ⇒ accepted inbound.
   *Because that same zone is also active on the LAN interface, we bind published ports to the tailscale IP (§5.1).*
8. CI base image `localhost/claude-devcontainer:latest` present (Node 24/Bun/Rust/TS/Python/git) — ready CI env.
9. **No host sudo required** for the whole implementation. `dev` has none and needs none.

## 4. Architecture

```
                        tailnet tail76c33c.ts.net (MagicDNS, WireGuard)
                       ┌───────────────────────────────────────────────┐
   aura-farming        │              devbox  (100.65.243.16)            │
   (100.104.230.32)    │   rootless podman (dev), systemd --user, linger │
   ┌──────────────┐    │   ┌─────────────────────────────────────────┐  │
   │ dev containers│────┼──▶│ forgejo  bind 100.65.243.16:3000 & :2222 │  │
   │  reach via    │    │   │ sqlite3, data on forgejo-data volume      │  │
   │  tailnet      │    │   ├─────────────────────────────────────────┤  │
   └──────────────┘    │   │ forgejo-runner (host executor, cap=1)     │  │
   devbox's own   ─────┼──▶│ image = claude-devcontainer + runner bin  │  │
   containers (hairpin)│   ├─────────────────────────────────────────┤  │
                       │   │ forgejo-dump.timer → nightly dump          │  │
                       │   └───────────┬───────────────┬───────────────┘  │
                       └───────────────┼───────────────┼──────────────────┘
                          push mirror   ▼       dump rsync ▼ (over tailnet)
                          github.com/<user>/<repo>     aura-farming:~/forgejo-backups
                          (one-way backup)             (issues/PRs/settings/CI history)
```

- **Canonical URLs** (identical from every container on either laptop):
  - Web / HTTP git: `http://devbox.tail76c33c.ts.net:3000`
  - SSH git: `ssh://git@devbox.tail76c33c.ts.net:2222/<owner>/<repo>.git`
- Forgejo + runner + backup are **rootless podman via Quadlet** (systemd `--user`), boot-started via `[Install]`.

## 5. Components

### 5.1 Forgejo service (Quadlet)

- Image **`codeberg.org/forgejo/forgejo:15`** (LTS; confirm latest at build). No `AutoUpdate` — update manually after a dump.
- SQLite; built-in Go SSH server (`START_SSH_SERVER=true`), container `:22` → host `:2222`.
- **Ports bound to the tailscale IP** so Forgejo is not exposed on the home LAN.
- `DEFAULT_ACTIONS_URL=https://data.forgejo.org` so unqualified `uses: actions/checkout@v4` resolve.
- Data on `forgejo-data` volume. **btrfs:** `chattr +C` the backing dir before first run (SQLite CoW fragmentation).
- Registration disabled after the first admin user.

### 5.2 CI runner (host executor, no podman socket)

Tests+lint only ⇒ no per-job isolation needed; host executor is the simplest robust rootless path.

- Runner image **FROM `localhost/claude-devcontainer:latest`** + the `forgejo-runner` binary copied from the
  official runner image (multi-stage). Jobs run inside this container, which already has the toolchains.
- **Security (host executor caveats):** jobs share the runner container's filesystem and can read/mutate `/data`
  (including the `.runner` registration state). Acceptable for single-user trusted repos, **not** arbitrary
  contributors. Mitigations: `runner.capacity=1`, per-job `timeout`, `host.workdir_parent=/data/work`, and
  **do not mount `persist`, SSH keys, or any personal material into the runner.**
- Reaches Forgejo over the shared `forgejo` podman network (`http://forgejo:3000`); `actions/checkout` against the
  public `ROOT_URL` is a verified hairpin.
- **Fallback** if host executor proves limiting: docker executor via the rootless podman socket
  (`systemctl --user enable --now podman.socket`, mount the socket, `container.force_pull=false`). Most likely
  friction point; validate the host executor first.

### 5.3 GitHub backup mirror

- Per-repo **push mirror** Forgejo → `https://github.com/<user>/<repo>.git` with a GitHub PAT (repo scope).
  **One-way.** If devbox is down and you push directly to GitHub, you must reconcile back into Forgejo before the
  next mirror sync (otherwise the mirror push can conflict/clobber). Runbook: `git -C <repo> push forgejo` (or
  temporarily disable the Forgejo push mirror, pull GitHub into Forgejo, re-enable).
- GitHub repo must exist (create empty first or via API). Forgejo runs on the host → outbound to github.com is open.

### 5.4 Backups (phase one, not "future")

GitHub mirror covers **code only** — not issues, PRs, settings, runner state, or CI history. So:

- `forgejo-dump.service` (oneshot, `--user`) runs `podman exec forgejo forgejo dump` into `/data/backups`,
  `podman cp`s it to the host, and `rsync -e ssh`s it to `aura-farming:~/forgejo-backups/` over the tailnet.
- `forgejo-dump.timer` runs it nightly; retain N copies.
- **Prereq:** an SSH key on the devbox host trusted by aura-farming (separate from the in-container agent key).

## 6. File-by-file changes

New dir `~/repos/devcontainer-base/forgejo/`; Quadlet files copied to `~/.config/containers/systemd/`.

### 6.1 Quadlet + image files

> **MATERIALIZED (rev 6).** These now exist as real, paste-ready files in [`forgejo/`](forgejo/) with
> the C1–C7 fixes applied (notably: `:U` removed from `forgejo-data`, `StartLimitIntervalSec=0`/`RestartSec=10`
> on both units, `FORGEJO__database__PATH` pinned, full-line comments only, runner config with
> `runner.file`). **The snippets below are illustrative design reference only** — do not paste them
> literally; copy from `forgejo/` and follow `forgejo/README.md`.

**`forgejo/forgejo.network`**
```ini
[Network]
NetworkName=forgejo
```

**`forgejo/forgejo-data.volume`** / **`forgejo/forgejo-runner-data.volume`**
```ini
[Volume]
VolumeName=forgejo-data        # and forgejo-runner-data in the second file
```

**`forgejo/forgejo.container`**
```ini
[Unit]
Description=Forgejo git server
After=network-online.target

[Container]
ContainerName=forgejo
Image=codeberg.org/forgejo/forgejo:15
Network=forgejo.network
PublishPort=100.65.243.16:3000:3000
PublishPort=100.65.243.16:2222:22
Volume=forgejo-data.volume:/data
Volume=/etc/localtime:/etc/localtime:ro
Environment=USER_UID=1000
Environment=USER_GID=1000
Environment=FORGEJO__server__DOMAIN=devbox.tail76c33c.ts.net
Environment=FORGEJO__server__ROOT_URL=http://devbox.tail76c33c.ts.net:3000/
Environment=FORGEJO__server__SSH_DOMAIN=devbox.tail76c33c.ts.net
Environment=FORGEJO__server__SSH_PORT=2222
Environment=FORGEJO__server__SSH_LISTEN_PORT=22
Environment=FORGEJO__server__START_SSH_SERVER=true
Environment=FORGEJO__server__HTTP_PORT=3000
Environment=FORGEJO__database__DB_TYPE=sqlite3
Environment=FORGEJO__service__DISABLE_REGISTRATION=true
Environment=FORGEJO__actions__ENABLED=true
Environment=FORGEJO__actions__DEFAULT_ACTIONS_URL=https://data.forgejo.org

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

**`forgejo/runner/Dockerfile`** (multi-stage; confirm runner major + binary path)
```dockerfile
FROM data.forgejo.org/forgejo/runner:12 AS runnerbin    # confirm current major
FROM localhost/claude-devcontainer:latest
COPY --from=runnerbin /bin/forgejo-runner /usr/local/bin/forgejo-runner   # verify source path
USER node
```

**`forgejo/runner/config.yml`** (mounted into the runner)
```yaml
log:
  level: info
runner:
  capacity: 1
  timeout: 30m
  labels:
    - devcontainer:host
host:
  workdir_parent: /data/work
```

**`forgejo/forgejo-runner.container`**
```ini
[Unit]
Description=Forgejo Actions runner
After=forgejo.service
Requires=forgejo.service

[Container]
ContainerName=forgejo-runner
Image=localhost/forgejo-runner:latest
Network=forgejo.network
Volume=forgejo-runner-data.volume:/data:U
Volume=%h/repos/devcontainer-base/forgejo/runner/config.yml:/data/config.yml:ro
WorkingDir=/data
Exec=forgejo-runner daemon --config /data/config.yml

[Service]
Restart=always

[Install]
WantedBy=default.target
```

**`forgejo/forgejo-dump.service` / `.timer`** + **`forgejo/forgejo-backup.sh`** — oneshot dump → `podman cp` →
`rsync` to aura-farming; daily timer. (Files sketched at implementation; depends on the devbox→aura-farming SSH key.)

### 6.2 Container firewall change — base script only, applied non-disruptively

> **RECONCILED / IMPLEMENTED (rev 4).** This step is now in `init-firewall.sh` and **unified
> with the Dolt remotesapi port**: the allow-block covers tcp **3000, 2222, and 50051** to the
> devbox tailscale IP as a single block. Do **not** apply a separate Forgejo-only or Dolt-only
> rule — it would duplicate the committed block. The snippet below is kept (updated to the
> unified form) for context only. Canonical source: `init-firewall.sh`; the beads/Dolt rationale
> is in `dolt/README.md` (Firewall).

**Only the base-image `init-firewall.sh` matters at runtime** (see changelog R1; the `musi`/`ma-toki`
`.devcontainer/init-firewall.sh` copies are vestigial and not used). So there is exactly **one file to edit** and
it only takes effect when a project re-pulls the rebuilt base.

**Persistent rule (edit the base script):** in `~/repos/devcontainer-base/init-firewall.sh`, insert **after** the
`-m set --match-set allowed-domains dst -j ACCEPT` line and **before** the final `REJECT` — explicit, port-scoped,
validated-as-tailnet rules (replaces the rev-1 ipset `/32`):

```bash
# Allow ONLY Forgejo (3000/2222) + Dolt remotesapi (50051) to the devbox host, and only if it
# resolves into the tailnet range. (Unified block — mirrors the committed init-firewall.sh.)
DEVBOX_HOST="devbox.tail76c33c.ts.net"
devbox_ip=$(dig +short A "$DEVBOX_HOST" 2>/dev/null | head -n1 || true)
if [ -z "$devbox_ip" ]; then devbox_ip="100.65.243.16"; fi          # fallback if MagicDNS unresolved
if [[ "$devbox_ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then   # 100.64.0.0/10
    for port in 3000 2222 50051; do   # Forgejo http, Forgejo ssh, Dolt remotesapi (beads)
        iptables -A OUTPUT -p tcp -d "$devbox_ip" --dport "$port" -j ACCEPT
    done
    echo "Allowed devbox services at $devbox_ip on tcp/{3000,2222,50051}"
else
    echo "WARN: $DEVBOX_HOST resolved to '$devbox_ip' (not in 100.64.0.0/10) — skipping devbox allow"
fi
```
Return traffic is covered by the existing ESTABLISHED ACCEPT rules.
*(Fallback if `dig` can't resolve MagicDNS at firewall time: hardcode `forgejo_ip=100.65.243.16`.)*

**Rollout is two-phase to avoid any teardown of running containers:**

- **Phase 5a — live, now, zero restart.** For each *enforcing* container, insert the same rule live (no host sudo,
  no restart; uses root-in-container via rootless `podman exec -u root`). Insert at the top so it precedes the REJECT:
  ```bash
  for p in 3000 2222 50051; do   # 50051 = Dolt remotesapi (beads); see dolt/README.md (Firewall)
    podman exec -u root ma-toki iptables -I OUTPUT 1 -p tcp -d 100.65.243.16 --dport "$p" -j ACCEPT
  done
  ```
  **musi needs nothing** — its firewall is intentionally disabled (policy ACCEPT), so it already reaches Forgejo.
  Caveat: a live rule is wiped if that container restarts (postStart re-runs the not-yet-updated baked script).

- **Phase 5b — persistent, deferred.** Land the base edit by running `./build.sh` (non-disruptive on its own — it
  only builds an image), then let each project pick up the new base **at its next natural rebuild** — no need to
  force `devcontainer-rebuild.sh`. After 5b, the rule survives restarts and the live 5a rules become redundant.
  When musi's firewall is eventually re-enabled/rebuilt, it inherits the baked rule automatically.

## 7. Implementation sequence (no host sudo, non-disruptive)

> **Canonical, copy-pasteable version of this sequence lives in [`forgejo/README.md`](forgejo/README.md)**
> (Install sequence), with the exact `cp`/`podman build`/`register` commands against the materialized
> files. The outline below is retained for the disruption rationale.

Steps 1–4 create only new isolated rootless containers/services and **do not restart or rebuild musi/ma-toki**.
Step 5 is split (5a live / 5b deferred) so nothing forces a disruptive `devcontainer-rebuild.sh`.

1. **Forgejo up:**
   ```bash
   mkdir -p ~/.config/containers/systemd
   cp ~/repos/devcontainer-base/forgejo/*.network ~/repos/devcontainer-base/forgejo/*.volume \
      ~/repos/devcontainer-base/forgejo/forgejo.container ~/.config/containers/systemd/
   systemctl --user daemon-reload            # generates + boot-enables via [Install]
   # chattr +C the forgejo-data backing dir before first write, then:
   systemctl --user start forgejo.service    # immediate run (boot is handled by [Install])
   ```
2. Browse `http://devbox.tail76c33c.ts.net:3000`, create admin, add your SSH pubkey, confirm registration disabled.
3. **Runner:** build image, register once (`:U` keeps `/data` writable for `node`), then start:
   ```bash
   podman build -t localhost/forgejo-runner:latest ~/repos/devcontainer-base/forgejo/runner
   podman run --rm -it --network forgejo -v forgejo-runner-data:/data:U -w /data \
     localhost/forgejo-runner:latest forgejo-runner register --no-interactive \
       --instance http://forgejo:3000 --token <TOKEN> --name devbox-runner --labels devcontainer:host
   cp ~/repos/devcontainer-base/forgejo/forgejo-runner.container ~/.config/containers/systemd/
   systemctl --user daemon-reload && systemctl --user start forgejo-runner.service
   ```
4. **Backups:** install `forgejo-dump.{service,timer}`; ensure devbox→aura-farming SSH works; `systemctl --user start forgejo-dump.timer`.
5. **Container firewall (non-disruptive, see §6.2):**
   - **5a (now):** live-insert the rule (tcp 3000/2222/**50051**) into ma-toki via `podman exec -u root` (zero restart). musi needs nothing (firewall intentionally off).
   - **5b (deferred):** the base `init-firewall.sh` edit is **already committed** (unified Forgejo+Dolt block); just run `./build.sh` so projects inherit it at their next natural rebuild — no forced `devcontainer-rebuild.sh`.
6. **Per repo (start with one):** create in Forgejo → on host `git remote set-url origin ssh://git@devbox.tail76c33c.ts.net:2222/<owner>/<repo>.git` → push → add GitHub push mirror → add `.forgejo/workflows/ci.yml` (`runs-on: devcontainer`).

## 8. Acceptance tests

1. `systemctl --user status forgejo forgejo-runner` active; `podman ps` healthy.
2. Host: `curl -fsS http://devbox.tail76c33c.ts.net:3000/api/v1/version` → JSON.
3. **Enforcing container (ma-toki, after 5a):** curl to Forgejo succeeds; a curl to a *non*-Forgejo tailnet port is still rejected. (musi: curl succeeds because its firewall is intentionally off — no isolation assertion there.)
4. **aura-farming** (host + container): curl succeeds over the tailnet.
5. **LAN isolation:** from a host on `192.168.1.0/24` that is *not* on the tailnet, `http://192.168.1.37:3000` is **refused** (ports bound to the tailscale IP).
6. **Reboot:** after rebooting devbox, forgejo + runner come back automatically (linger + `[Install]`).
7. **Runner `/data` writable:** registration + a job write under `/data/work` succeed (no permission errors).
8. Push a repo over SSH; it appears in the UI. A pushed workflow is picked up and passes.
9. Push mirror appears on GitHub after a sync.
10. **Outage recovery:** simulate devbox-down → push to GitHub → run the §5.3 reconciliation → Forgejo and mirror are consistent. Verify a `forgejo dump` lands on aura-farming.

## 9. Rollback

```bash
systemctl --user disable --now forgejo-dump.timer 2>/dev/null
systemctl --user stop forgejo.service forgejo-runner.service forgejo-dump.timer
rm ~/.config/containers/systemd/forgejo*.{container,network,volume}
rm ~/.config/containers/systemd/forgejo-dump.{service,timer} 2>/dev/null
systemctl --user daemon-reload
podman volume rm forgejo-data forgejo-runner-data   # destroys repos/issues/CI history (mirror + dumps remain)
# revert init-firewall.sh edits in base + musi + ma-toki, then rebuild chain
```

## 10. Residual risks / things to validate during implementation

1. **Runner execution model** — host executor needs validation that `actions/checkout` + JS actions run cleanly;
   docker-executor fallback documented (§5.2).
2. **Tailscale IP stability** — ports + firewall both key off `100.65.243.16`. If the node IP ever changes, update
   `PublishPort` and re-resolve in the firewall (the firewall already re-resolves by name each start).
3. **`dig` resolving MagicDNS at firewall-setup time** — `getent` is verified; confirm `dig` path or hardcode (§6.2).
4. **Boot ordering** — `tailscale0`/IP may not be up when the user manager starts; `Restart=always` retries the
   IP-bound publish until it succeeds. Verify via the reboot test (§8.6).
5. **Forgejo runner image** — confirm current runner major + the binary's path inside the official image.
6. **Registry reachability** — host must reach `codeberg.org` + `data.forgejo.org` at build/pull (host is outside
   the container firewall → expected fine).
7. **SSH host-key trust** for non-interactive git from containers/CI (seed `known_hosts` or `StrictHostKeyChecking accept-new`).
8. **Availability** — devbox asleep/off ⇒ no Forgejo for aura-farming (accepted). Mirror = code backup only; dumps
   (§5.4) cover the rest. Direct-to-GitHub pushes need the §5.3 reconciliation.

## 11. Out of scope / future

- HTTPS via `tailscale serve` (real cert, drop `:3000`) if plain HTTP gets annoying.
- Postgres backend if usage grows.
- Image-building CI (needs privileged/dind or buildah-in-podman).
- Multi-node HA / always-on dedicated host.

## 12. Reviewer note carried forward

The external review could not verify local podman details (the sandbox made `/run/user/1003/libpod` read-only); the
document review didn't depend on it. The runtime checks in §3 were performed by this agent directly on devbox.
