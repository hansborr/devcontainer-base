# Forgejo + local CI on devbox

This directory is the **devbox-specific, paste-ready realization** of `../forgejo-setup-plan.md`
(the design doc + changelog/rationale, co-located at this repo's root). The plan explains *why*;
these files are the *how* — installable Quadlet units, the runner image, the backup job, and this
guide. Same environment as the Dolt remote next door (`../dolt/`): **rootless podman + Quadlet +
systemd `--user` (linger), no host sudo**. Where the plan's inline snippets and these files
disagree, **these files win** (they have the rev-5/rev-6 review fixes baked in; the plan's snippets
were illustrative and carried trailing comments that would corrupt a literal paste).

> Status: **DEPLOYED on devbox 2026-06-20** (Forgejo 15.0.3, runner v12.12.0). Forgejo + runner are
> running and boot-enabled; the nightly dump timer is enabled. The musi/ma-toki devcontainers were
> **not** restarted or rebuilt. Two follow-ups remain (both user-side): the host→aura-farming SSH key
> for the offsite backup copy, and per-repo onboarding + the GitHub push-mirror. See
> `../forgejo-setup-plan.md` §7 for the non-disruptive sequencing.
>
> **Deploy-time fixes (applied to the units here — the plan snippets predate them):**
> 1. **SSH port** — rootless podman can't bind container `:22` as the unprivileged git user
>    (`bind: permission denied`), so the built-in Go SSH server listens on **2222 inside** the
>    container and we publish `2222:2222` straight through (`SSH_LISTEN_PORT=2222`). The external
>    clone port is still **2222** — unchanged.
> 2. **`INSTALL_LOCK=true`** — added `FORGEJO__security__INSTALL_LOCK=true` so the instance is fully
>    config-driven (no web-installer round-trip); Forgejo auto-generates `SECRET_KEY`/`INTERNAL_TOKEN`
>    on first start. The admin user is created via `forgejo admin user create` (step 2 below), not the UI.
> 3. **SELinux `,z`** on the runner's `config.yml` bind-mount — required on this enforcing-SELinux
>    host (`user_home_t` → `container_file_t`), same fix + rationale as `dolt.container`.

## What's here

| File | Role |
|---|---|
| `forgejo.container` | Quadlet unit for `codeberg.org/forgejo/forgejo:15` (LTS), bound to the tailscale IP. Boot-starts via `[Install]` + linger. |
| `forgejo.network` | Shared podman network so the runner reaches Forgejo at `http://forgejo:3000`. |
| `forgejo-data.volume` / `forgejo-runner-data.volume` | Persistent Quadlet volumes (repos+db / runner state). |
| `runner/Dockerfile` | Multi-stage build: `forgejo-runner` binary on top of `localhost/claude-devcontainer:latest`. |
| `runner/config.yml` | Host-executor runner config (secret-free; mounted read-only). |
| `forgejo-runner.container` | Quadlet unit for the runner. |
| `forgejo-dump.service` / `.timer` / `forgejo-backup.sh` | Nightly `forgejo dump` → rsync to aura-farming. |
| `.env.example` | Copy to `.env` (gitignored) — backup target host + retention. |

## Confirmed against upstream (June 2026)

- **Forgejo `:15`** is the current LTS (supported to **2027-07-15**); bare `:15` tracks the latest
  patch in the LTS line. `codeberg.org` is canonical (data/code.forgejo.org are mirrors).
- **Runner `:12`** is the current major; binary is at `/bin/forgejo-runner` in
  `data.forgejo.org/forgejo/runner:12`.
- All `FORGEJO__…` env keys and `DEFAULT_ACTIONS_URL=https://data.forgejo.org` verified current.
- **Tailscale IP `100.65.243.16`** re-confirmed at write time (MagicDNS resolves on-host); ports
  3000/2222/50051 free; base image present; linger on.

## Install sequence (no host sudo)

```bash
# 1. Forgejo
mkdir -p ~/.config/containers/systemd
cp ~/repos/devcontainer-base/forgejo/forgejo.network \
   ~/repos/devcontainer-base/forgejo/forgejo-data.volume \
   ~/repos/devcontainer-base/forgejo/forgejo-runner-data.volume \
   ~/repos/devcontainer-base/forgejo/forgejo.container ~/.config/containers/systemd/
# config.yml + the backup script are mounted/run directly from this repo dir — not copied.
systemctl --user daemon-reload          # generates units + boot-enables via [Install]
# btrfs: chattr +C the forgejo-data backing dir BEFORE first write (sqlite CoW fragmentation):
#   d=$(podman volume inspect forgejo-data --format '{{.Mountpoint}}'); chattr +C "$d" 2>/dev/null || true
systemctl --user start forgejo.service
```

2. **Admin user (CLI, config-driven).** With `INSTALL_LOCK=true` (see Deploy-time fixes) there is no
   web installer — create the admin out-of-band and generate the runner token via CLI:
   ```bash
   # strong password (guaranteed upper/lower/digit); report it, change it in the UI after.
   PW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)Aa9"; echo "admin pw: $PW"
   podman exec -u 1000 forgejo forgejo admin user create --admin \
     --username <you> --email <you@example.com> --password "$PW" --must-change-password=false
   # add your SSH pubkey (host key shown) so host-side `git push` over :2222 works:
   curl -fsS -u "<you>:$PW" -X POST http://devbox.tail76c33c.ts.net:3000/api/v1/user/keys \
     -H 'Content-Type: application/json' \
     -d "{\"title\":\"devbox-host\",\"key\":\"$(cat ~/.ssh/id_ed25519.pub)\"}"
   # runner registration token for step 3 (or use the UI: Site Admin → Actions → Runners):
   podman exec -u 1000 forgejo forgejo actions generate-runner-token
   ```

3. **Runner** — build the image, register once, then start the unit:
   ```bash
   podman build -t localhost/forgejo-runner:latest ~/repos/devcontainer-base/forgejo/runner
   # one-time register: writes /data/.runner on the runner-data volume (:U keeps it node-writable)
   podman run --rm -it --network forgejo -v forgejo-runner-data:/data:U -w /data \
     localhost/forgejo-runner:latest forgejo-runner register --no-interactive \
       --instance http://forgejo:3000 --token <TOKEN> --name devbox-runner --labels devcontainer:host
   cp ~/repos/devcontainer-base/forgejo/forgejo-runner.container ~/.config/containers/systemd/
   systemctl --user daemon-reload && systemctl --user start forgejo-runner.service
   ```

4. **Backups** — `cp .env.example .env` and set the aura-farming target; ensure the devbox **host**
   `dev` user has an SSH key trusted by aura-farming (separate from the in-container agent key); then:
   ```bash
   # .service/.timer are PLAIN systemd user units (not Quadlet) → ~/.config/systemd/user/.
   # Only .container/.network/.volume go in ~/.config/containers/systemd/.
   mkdir -p ~/.config/systemd/user
   cp ~/repos/devcontainer-base/forgejo/forgejo-dump.service \
      ~/repos/devcontainer-base/forgejo/forgejo-dump.timer ~/.config/systemd/user/
   # `enable --now`, NOT just `start`: these are plain units, so unlike the Quadlet
   # units above (whose [Install] is processed by the generator on daemon-reload) the
   # timer's [Install] only takes effect via `enable` — `start` alone runs it for this
   # session but leaves no timers.target.wants symlink, so it would NOT come back after
   # a reboot. `enable --now` both installs the boot symlink and starts it immediately.
   systemctl --user daemon-reload && systemctl --user enable --now forgejo-dump.timer
   systemctl --user start forgejo-dump.service   # run once now to verify a dump lands on aura-farming
   ```

5. **Per repo** — create it in Forgejo, then on the host:
   ```bash
   git remote set-url origin ssh://git@devbox.tail76c33c.ts.net:2222/<owner>/<repo>.git
   git push -u origin --all
   # add a GitHub push-mirror in the repo's Settings → Mirroring (one-way backup)
   # add .forgejo/workflows/ci.yml with `runs-on: devcontainer`
   ```

## Ownership (the `:U` decision — resolves review item C4)

`forgejo-data` deliberately has **no `:U`**, but `forgejo-runner-data` does. Not an oversight:

- The **Forgejo** image runs a **root entrypoint** that creates the git user as `USER_UID:USER_GID`
  (1000:1000, set in `forgejo.container`) and chowns `/data` itself. `:U` would *recursively re-chown
  the entire — and growing — repo tree on every start*, which is slow and pointless. So we let the
  image own it.
- The **runner** runs as `USER node` with **no chowning entrypoint**, and its volume is tiny
  (registration file + job work dirs), so `:U` is both necessary (first write would otherwise fail on
  a UID mismatch) and cheap.

If `forgejo.service` ever fails writing `/data`, check `podman logs forgejo` and confirm
`USER_UID`/`USER_GID` match the volume owner — same failure mode the Dolt README flags.

## Runner registration — two flows

**Default (these files): `register` + `.runner`.** The committed `config.yml` is **secret-free**; the
registration secret lives in `/data/.runner` on the volume (step 3). As of Forgejo 15 the `register`
command is *deprecated* (prints a warning) but fully functional, and the `.runner` mechanism is
supported for the foreseeable future. This flow is chosen because it keeps secrets out of the
repo-mounted config, matching this repo's hygiene (cf. Dolt's gitignored `.env`).

**Future-proof alternative: config-declared connection.** Forgejo 15's new model skips `register`
entirely — create the runner in the UI, get its **UUID + token**, and put them in `config.yml`:
```yaml
server:
  connections:
    devbox:
      url: http://forgejo:3000/
      uuid: <from UI>
      token: <from UI>
      labels:
        - devcontainer:host
```
Then drop `runner.file`. **This puts a secret in `config.yml`** — if you adopt it, copy the committed
file to `config.yml.example`, gitignore the real `config.yml`, and keep the secret out of git. Either
flow works; pick one. Labels must be identical wherever they appear or `runs-on: devcontainer` jobs
won't be picked up.

## Backups

`forgejo-backup.sh` runs `forgejo dump` inside the container (captures issues/PRs/settings/attachments/
CI history + the sqlite DB — everything the GitHub mirror misses), copies the archive out, and rsyncs
it to aura-farming over the tailnet, pruning to `RETENTION`. Prereqs: the host `dev` user's SSH key
trusted by aura-farming, and `.env` filled in. **Validate on first run** (`systemctl --user start
forgejo-dump.service`): the `--config /data/gitea/conf/app.ini` path assumes the **standard** image
(the rootless image would be `/etc/gitea/app.ini`).

## Firewall — already handled (do NOT add a second rule)

The dev containers run a default-DROP egress firewall. `init-firewall.sh` already allows
`3000/2222/50051` to the devbox tailscale IP in a **single unified block** (Forgejo + Dolt). Do not add
a Forgejo-only rule — it would duplicate the committed block. For an already-running *enforcing*
container (e.g. ma-toki), live-insert without a restart:
```bash
for p in 3000 2222 50051; do
  podman exec -u root ma-toki iptables -I OUTPUT 1 -p tcp -d 100.65.243.16 --dport "$p" -j ACCEPT
done
```
musi needs nothing (its firewall is intentionally policy-ACCEPT). The baked rule lands for everyone at
the next base rebuild (`./build.sh` → projects re-pull base). The **runner** container has *no* egress
firewall (it's a plain Quadlet container, not a devcontainer), so CI jobs get broader outbound than
the dev containers — accept + document (review item C2), and never mount `persist`/SSH keys/personal
material into it.

## Validation points / known snags

1. **Runner → public `ROOT_URL` reachability (item 6 / most likely snag).** The runner registers over
   the internal `http://forgejo:3000`, but `actions/checkout` clones via Forgejo's advertised
   `ROOT_URL` (`http://devbox.tail76c33c.ts.net:3000/`). The runner container must **resolve MagicDNS
   and hairpin to the tailscale IP**. Verify after step 3 with a trivial workflow that runs
   `actions/checkout`; if it hangs/fails while registration succeeded, that's this. Fix: confirm the
   MagicDNS name resolves inside the runner, or add a host alias mapping it to the `forgejo` container.
2. **musl→glibc binary.** `forgejo-runner` is copied from an Alpine image onto the Debian base. It's a
   static Go binary so it should just run — the `RUN forgejo-runner --version` in the Dockerfile
   smoke-tests this at build time. If it ever fails, download the release binary instead of copying it.
3. **`forgejo dump` config path** — see Backups; validate on first run.
4. **SQLite on btrfs** — `chattr +C` the `forgejo-data` backing dir before first write (install step 1).
5. **Boot race** — units bind the tailscale IP but only set `Restart=always`; `StartLimitIntervalSec=0`
   + `RestartSec=10` (review item C3, applied to both units) keep them retrying until `tailscale0` has
   the IP. Verify with the reboot test.

## Acceptance tests (condensed — full list in plan §8)

1. `systemctl --user status forgejo forgejo-runner` active; `podman ps` healthy.
2. Host: `curl -fsS http://devbox.tail76c33c.ts.net:3000/api/v1/version` → JSON.
3. **From enforcing ma-toki** (after the firewall live-insert): curl to Forgejo `:3000` succeeds; curl
   to a *non*-allowlisted tailnet port is still refused (isolation intact).
4. Push a repo over SSH (`:2222`); it appears in the UI. A pushed `.forgejo/workflows/ci.yml` is picked
   up by the runner and passes (exercises the item-1 reachability path end-to-end).
5. GitHub push-mirror appears after a sync.
6. **Reboot** devbox → forgejo + runner come back automatically (Quadlet `[Install]` + linger),
   and the dump timer comes back **only if it was `enable`d** (step 4) — confirm with
   `systemctl --user is-enabled forgejo-dump.timer` → `enabled`.
7. `systemctl --user start forgejo-dump.service` → a dump lands in `aura-farming:~/forgejo-backups/`.

## Availability

Both Forgejo and Dolt live on devbox, so when devbox sleeps aura-farming loses both. Unlike Dolt's
offline-tolerant beads sync, **Forgejo is hard-down** when devbox is off — the GitHub mirror (code) +
nightly dumps (everything else) are the backstop. If you push directly to GitHub during an outage,
reconcile back into Forgejo before the next mirror sync (plan §5.3).
