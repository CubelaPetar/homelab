# cloud VPS — Backup Strategy

## Architecture context

- **cloud** is a dual-stack VPS running Docker Compose stacks managed by Ansible.
- `appdata_path` is `/home/petar/appdata` — all persistent service state lives under this tree.
- The only service with user data that cannot be re-created is **Nextcloud**, backed by a **MariaDB** container (`mariadb`) and storing files under `appdata/nextcloud/data/`.
- **WireGuard** is the VPN hub for the site-to-site tunnel to home and road warrior access. Its config (`/etc/wireguard/wg0.conf`) contains the VPS private key and all peer public keys — losing it means regenerating keys and reconfiguring all peers.
- **Traefik** stores ACME certificates in `appdata/traefik/letsencrypt/acme.json`. Losing them is not catastrophic (Let's Encrypt will re-issue), but re-issuance counts toward rate limits and causes a brief service interruption.
- **Static sites** (`petarcubela.de`, `rezepte.petarcubela.de`) have their content managed as Hugo projects in separate git repositories. Only the pre-built `public/` directories live in `appdata/`. These are intentionally excluded from backup — a `hugo build` redeploy recreates them instantly.
- **SearXNG** has no user data worth preserving. Its `appdata/searxng/` directory contains a settings file that can be redeployed from Ansible in minutes.
- **Valkey/Redis** (used by SearXNG) — ephemeral cache, excluded.

```
Daily:
  03:00 — backup-cloud.sh
             enable Nextcloud maintenance mode
             ↓
             stop mariadb container (DB files now cold — safe to copy)
             ↓
             restic backup: appdata/ (excl. static sites, searxng, valkey)
                          + /etc/wireguard/
             ↓
             start mariadb container
             ↓
             disable Nextcloud maintenance mode
             ↓
             restic copy appdata + wireguard snapshots → Hetzner
             ↓
             prune local + remote repos
```

---

## What is backed up

| Source | Method | Local | Hetzner |
|---|---|---|---|
| `appdata/nextcloud/` (config + data files) | restic (DB cold) | ✓ daily | ✓ daily |
| `appdata/databases/nc_db/` (MariaDB data dir) | restic (container stopped) | ✓ daily | ✓ daily |
| `appdata/traefik/letsencrypt/` (ACME certs) | restic | ✓ daily | ✓ daily |
| `/etc/wireguard/` (WireGuard keys + config) | restic | ✓ daily | ✓ daily |

**Not backed up (intentional):**

| Source | Reason |
|---|---|
| `appdata/petarcubela/public/` | Hugo build output — recreated by `hugo build` from git repo |
| `appdata/rezepte/public/` | Same — separate git repo |
| `appdata/searxng/` | Ansible-managed config; no user data |
| `appdata/valkey-data2/` | SearXNG cache; ephemeral |
| `appdata/databases/petarcubela_*` | Only Nextcloud has a DB on this host |

---

## MariaDB consistency strategy

MariaDB uses InnoDB. Copying live InnoDB data files without stopping the engine risks capturing a torn page mid-write. The approach mirrors turtle's media VM shutdown:

1. Enable Nextcloud maintenance mode — Nextcloud stops processing requests and holds new writes. The web container continues running (so the `occ` command works), but no user can write to the DB.
2. Stop the `mariadb` container — the InnoDB engine flushes and closes all files cleanly.
3. restic backs up the cold `appdata/databases/nc_db/` directory — consistent and safe.
4. Start `mariadb` again.
5. Disable Nextcloud maintenance mode.

Total downtime for Nextcloud: typically 2–5 minutes (restic on a small appdata is fast on a VPS with local disk).

> **Why not `mysqldump`?** A SQL dump is portable and easy to restore into any MySQL instance, but it requires `mysqldump` to be available inside the container and adds complexity (dump file path, cleanup). For this setup the raw-files approach is simpler, faster (no serialisation), and produces a directly mountable backup. If the MariaDB data grows large or the restore story matters to you, add a `mysqldump` step before stopping the container and keep the `.sql` file alongside the raw data backup.

---

## Hetzner Storage Box setup

The Storage Box is already set up for turtle and petarcubela. Add a directory for cloud:

```bash
echo "mkdir backups/cloud" | sftp hetzner-box
```

(Run from turtle where the `hetzner-box` SSH alias is already configured, or from cloud once the SSH key is installed — see below.)

### SSH key on cloud (run as root)

```bash
ssh-keygen -t ed25519 -f /root/.ssh/hetzner_storagebox -C "cloud-restic" -N ""

ssh-copy-id -p 23 -i /root/.ssh/hetzner_storagebox.pub \
  u123456@u123456.your-storagebox.de
```

### `/root/.ssh/config` entry

```
Host hetzner-box
  HostName u123456.your-storagebox.de
  User u123456
  Port 23
  IdentityFile /root/.ssh/hetzner_storagebox
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Test: `sftp hetzner-box` — you should get an SFTP prompt.

> **No forced IPv6 needed here.** Unlike turtle (DS-Lite CGNAT), the cloud VPS has a native public IPv4 address, so long SFTP sessions do not get reset mid-upload. The default `AddressFamily any` works fine.

---

## restic setup

### Install

```bash
apt install restic
restic self-update   # apt version on Debian 12 is 0.15; self-update gets current release
```

### Password file

Use the **same passphrase** as turtle and petarcubela (one master passphrase for the whole Hetzner storage box):

```bash
echo "your-shared-passphrase" > /root/.restic-password
chmod 600 /root/.restic-password
```

### Initialise repositories

```bash
# Local repo (fast restore, kept short-term)
restic -r /root/restic-repo \
  --password-file /root/.restic-password init

# Remote repo on Hetzner (long-term offsite)
# --copy-chunker-params ensures identical chunking → dedup works correctly across repos
restic -r sftp:hetzner-box:backups/cloud \
  --password-file /root/.restic-password \
  init --copy-chunker-params --from-repo /root/restic-repo
```

> **Pitfall:** the SFTP path must be relative — no leading slash. `sftp:hetzner-box:backups/cloud` works. `sftp:hetzner-box:/backups/cloud` produces a misleading `SSH_FX_FAILURE` error even when the directory exists.

---

## Script

### `/usr/local/bin/backup-cloud.sh`

```bash
#!/usr/bin/env bash
# backup-cloud.sh
# Backs up Nextcloud (with MariaDB cold stop) and WireGuard config to
# local restic repo and Hetzner Storage Box.
# Runs at 03:00 daily via /etc/cron.d/cloud-backup.
set -euo pipefail

LOG="/var/log/cloud-backup.log"
TS=$(date +%Y%m%d-%H%M%S)
PW_FILE="/root/.restic-password"
LOCAL_REPO="/root/restic-repo"
REMOTE_REPO="sftp:hetzner-box:backups/cloud"
APPDATA="/home/petar/appdata"
NC_COMPOSE_DIR="/home/petar/docker/05-apps"

exec > >(tee -a "$LOG") 2>&1

log() { echo "[${TS}] $*"; }

restic_local()  { restic -r "$LOCAL_REPO"  --password-file "$PW_FILE" "$@"; }
restic_remote() { restic -r "$REMOTE_REPO" --password-file "$PW_FILE" "$@"; }

copy_to_remote() {
  local tag="$1" attempts=5 i
  for ((i=1; i<=attempts; i++)); do
    log "Copy --tag $tag to Hetzner (attempt $i/$attempts)"
    if restic -r "$REMOTE_REPO" --password-file "$PW_FILE" copy \
         --from-repo "$LOCAL_REPO" \
         --from-password-file "$PW_FILE" \
         --tag "$tag"; then
      log "Copy --tag $tag OK"
      return 0
    fi
    log "WARN: copy failed (attempt $i), retrying in 60s"
    sleep 60
  done
  log "ERROR: copy --tag $tag failed after $attempts attempts"
  return 1
}

log "=== cloud backup starting ==="

# ── 1. Enable Nextcloud maintenance mode ──────────────────────────────────────
log "Enabling Nextcloud maintenance mode"
docker exec nextcloud php occ maintenance:mode --on \
  && log "Maintenance mode ON" \
  || { log "ERROR: could not enable maintenance mode — aborting"; exit 1; }

# ── 2. Stop MariaDB (cold stop for consistent InnoDB files) ───────────────────
log "Stopping mariadb container"
docker compose -f "$NC_COMPOSE_DIR/compose.yml" stop mariadb \
  && log "mariadb stopped" \
  || {
    log "ERROR: could not stop mariadb — re-enabling maintenance mode and aborting"
    docker exec nextcloud php occ maintenance:mode --off
    exit 1
  }

# ── 3. restic backup ──────────────────────────────────────────────────────────
log "Backing up appdata and wireguard config"
restic_local backup \
  "$APPDATA/nextcloud" \
  "$APPDATA/databases/nc_db" \
  "$APPDATA/traefik/letsencrypt" \
  /etc/wireguard \
  --tag cloud \
  --exclude "lost+found" \
  --exclude "*.tmp" \
  && log "restic backup OK" \
  || {
    log "ERROR: restic backup failed — restarting mariadb and disabling maintenance mode"
    docker compose -f "$NC_COMPOSE_DIR/compose.yml" start mariadb
    docker exec nextcloud php occ maintenance:mode --off
    exit 1
  }

# ── 4. Restart MariaDB ────────────────────────────────────────────────────────
log "Starting mariadb container"
docker compose -f "$NC_COMPOSE_DIR/compose.yml" start mariadb
log "mariadb started"

# ── 5. Disable Nextcloud maintenance mode ─────────────────────────────────────
log "Disabling Nextcloud maintenance mode"
# Give MariaDB a moment to be ready before Nextcloud reconnects
sleep 10
docker exec nextcloud php occ maintenance:mode --off \
  && log "Maintenance mode OFF" \
  || log "WARN: could not disable maintenance mode automatically — run manually: docker exec nextcloud php occ maintenance:mode --off"

# ── 6. Prune local repo ───────────────────────────────────────────────────────
log "Pruning local repo"
restic_local forget \
  --keep-daily   7 \
  --keep-weekly  4 \
  --keep-monthly 3 \
  --prune

# ── 7. Copy to Hetzner ────────────────────────────────────────────────────────
copy_to_remote cloud

# ── 8. Prune remote ───────────────────────────────────────────────────────────
log "Pruning Hetzner repo"
restic_remote forget \
  --keep-daily   7 \
  --keep-weekly  4 \
  --keep-monthly 12 \
  --prune

log "=== cloud backup complete ==="
```

Install:

```bash
install -o root -g root -m 755 backup-cloud.sh /usr/local/bin/backup-cloud.sh
```

---

## Cron schedule

`/etc/cron.d/cloud-backup`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 03:00 daily — Nextcloud + WireGuard backup to local repo + Hetzner
0  3  * * *  root  /usr/local/bin/backup-cloud.sh
```

03:00 is chosen to avoid overlap with petarcubela's 06:25/07:00 window and turtle's 02:00–04:30 window — all three jobs hit the same Hetzner Storage Box sequentially.

---

## Retention

| Scope | Local (`/root/restic-repo`) | Hetzner |
|---|---|---|
| All data (appdata + wireguard) | 7 daily, 4 weekly, 3 monthly | 7 daily, 4 weekly, 12 monthly |

Local retention is shorter than turtle's because the cloud VPS typically has limited disk space. Adjust if the server has room to spare.

---

## Verification commands

```bash
# List all snapshots
restic -r /root/restic-repo --password-file /root/.restic-password snapshots

# List files in latest snapshot
restic -r /root/restic-repo --password-file /root/.restic-password ls latest

# Check repo integrity
restic -r /root/restic-repo --password-file /root/.restic-password check

# Test restore of Nextcloud config to /tmp
restic -r /root/restic-repo --password-file /root/.restic-password \
  restore latest --target /tmp/cloud-restore-test

# List WireGuard config in latest snapshot
restic -r /root/restic-repo --password-file /root/.restic-password \
  ls latest /etc/wireguard

# Verify Hetzner repo
restic -r sftp:hetzner-box:backups/cloud \
  --password-file /root/.restic-password snapshots

# Check Nextcloud maintenance mode is off after a test run
docker exec nextcloud php occ maintenance:mode
```

---

## First-run checklist

1. `apt install restic && restic self-update`
2. Generate `/root/.ssh/hetzner_storagebox` and install public key on Storage Box (port 23)
3. Add `hetzner-box` entry to `/root/.ssh/config`
4. Create `/root/.restic-password` (shared passphrase)
5. Create `backups/cloud` directory on the Storage Box: `echo "mkdir backups/cloud" | sftp hetzner-box`
6. `restic init` local repo; init remote with `--copy-chunker-params --from-repo`
7. Install and `chmod +x` `backup-cloud.sh`
8. Run manually once:
   ```bash
   /usr/local/bin/backup-cloud.sh
   tail -50 /var/log/cloud-backup.log
   ```
9. Confirm Nextcloud is accessible after the run (maintenance mode was disabled)
10. Install `/etc/cron.d/cloud-backup`
11. Check the log the next morning

---

## Future: Hermes (agentic AI)

When Hermes is deployed on this server, add its appdata path to the backup script.

Hermes will likely need:
- Its model cache or weights directory — evaluate size first; if large and re-downloadable, exclude like ollama models on turtle
- Its database (if any) — determine the engine and apply the same cold-stop or dump strategy as Nextcloud/MariaDB
- Its config/secrets directory — include unconditionally

Update `backup-cloud.sh` by adding the relevant paths to the `restic_local backup` call:

```bash
# Example — adjust paths once Hermes is deployed
restic_local backup \
  "$APPDATA/nextcloud" \
  "$APPDATA/databases/nc_db" \
  "$APPDATA/traefik/letsencrypt" \
  "$APPDATA/hermes" \           # ← add this
  /etc/wireguard \
  --tag cloud \
  ...
```

If Hermes uses a database, add a stop/start around it — or a dump step — before the restic call, following the same pattern as the MariaDB block above.

---

## Out of scope

| Host | Status | Notes |
|---|---|---|
| turtle | Separate doc | `docs/backup_strategy/20260612-turtle-backup-strategy-offsite_v3.md` |
| petarcubela | Separate doc | `docs/backup_strategy/20260610-petarcubela_backup_mailcow_restic.md` |
| llm host | Not covered | Appdata is NFS-served from turtle — covered by turtle's appdata backup |
