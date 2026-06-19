# Dolt shared remote on devbox (beads store)

This directory is the **devbox-specific** realization of `../dolt-remote-server-handoff.md`
(the generic handoff, co-located at this repo's root).
That handoff was written for a context-free agent and assumes Docker + `docker compose`.
devbox is **rootless podman + Quadlet + systemd --user (linger), no host sudo** — the same
environment as the Forgejo plan. These files override the handoff accordingly. Where they
disagree, **these files win**; use the handoff for the Dolt/beads concepts and §4–§6
(security, verification, gotchas).

## What's here

| File | Role |
|---|---|
| `dolt.container` | Quadlet unit for `dolthub/dolt-sql-server`, bound to the tailscale IP. Replaces the handoff's docker-compose so it **boot-starts via `[Install]` + linger** like Forgejo (a bare compose would not survive a reboot). |
| `dolt.volume` / `dolt.network` | Quadlet volume + network, parallel to the Forgejo units. |
| `servercfg.d/config.yaml` | Enables the `remotesapi` (:50051) port — the part beads actually uses. |
| `.env.example` | Copy to `.env` (gitignored) with the root password. |

## Reconciliation notes (the 5 things the handoff doesn't know about devbox)

1. **Firewall — already handled, in ONE place.** The dev containers run a default-DROP
   iptables firewall; beads sync on **50051** would be dropped from any *enforcing*
   container. The base `init-firewall.sh` now allows `3000/2222/50051` to the devbox
   tailscale IP in a single block. **Do not** also add the Forgejo-plan §6.2 block — this
   supersedes it. Live insert for an already-running enforcing container (e.g. ma-toki),
   zero restart:
   ```bash
   for p in 3000 2222 50051; do
     podman exec -u root ma-toki iptables -I OUTPUT 1 -p tcp -d 100.65.243.16 --dport "$p" -j ACCEPT
   done
   ```
   musi needs nothing (its firewall is intentionally policy-ACCEPT). The baked rule lands
   for everyone at the next base rebuild (`./build.sh` → projects re-pull base).

2. **Verify from an ENFORCING devcontainer, not a throwaway.** Handoff §5.3 clones with a
   bare `dolthub/dolt:latest` container that has **no** firewall, so it passes even when
   real clients are blocked. After standing the server up, do the real test from inside
   ma-toki:
   ```bash
   # inside the ma-toki devcontainer, after the firewall change:
   DOLT_REMOTE_USER=beads DOLT_REMOTE_PASSWORD=<sync-pw> \
     bd dolt pull   # (or a dolt clone of http://devbox.tail76c33c.ts.net:50051/musi)
   ```

3. **No Docker / no host sudo.** Translate handoff `docker …` → `podman …`. Install:
   ```bash
   cp ~/repos/devcontainer-base/dolt/dolt.network \
      ~/repos/devcontainer-base/dolt/dolt.volume \
      ~/repos/devcontainer-base/dolt/dolt.container ~/.config/containers/systemd/
   cp -r ~/repos/devcontainer-base/dolt/servercfg.d ~/.config/containers/systemd/  # if your unit path expects it; here it's mounted from the repo dir
   cd ~/repos/devcontainer-base/dolt && cp .env.example .env && $EDITOR .env
   systemctl --user daemon-reload
   systemctl --user start dolt.service
   ```
   Then create the DB + `beads` sync user per handoff §3.4 (connect to :3306 as root from
   the host — the host is outside the container firewall, so admin works). Don't forget the
   initial `CALL DOLT_COMMIT('--allow-empty', …)` or the first clone fails.

4. **Addressing & transport are decided** (answers handoff open-Qs #2/#3): plain `http`
   over the tailnet, MagicDNS name — matches Forgejo. Client remote URL:
   ```
   http://devbox.tail76c33c.ts.net:50051/musi
   ```

5. **Pin the image + back it up.** Start on `:latest`, run the round-trip in (2), then pin
   the exact tag in `dolt.container`. The `forgejo dump` backup does **not** cover Dolt —
   add the `dolt-data` volume (or a `dolt dump`) to the same nightly rsync-to-aura-farming
   routine if you want the issue graph backed up too.

## Possible snag

If `dolt.service` fails writing to `/var/lib/dolt` under rootless podman (UID mismatch),
add `:U` to the data volume mount in `dolt.container`
(`Volume=dolt-data.volume:/var/lib/dolt:U`) and restart — same fix the Forgejo runner uses.

## Availability

Both Forgejo and Dolt now live on devbox, so when devbox sleeps, aura-farming loses both.
Unlike Forgejo, beads push/pull is offline-tolerant: clients keep a local DB and just defer
sync until devbox is back — so this degrades gracefully.
