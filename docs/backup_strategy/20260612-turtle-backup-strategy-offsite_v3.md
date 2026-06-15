# Turtle NAS — Backup Strategy

## Architecture context

- **turtle** is a Proxmox PVE host acting as NAS and hypervisor. No Docker containers run on turtle itself.
- The `/mnt/ssd/appdata/` tree is served via NFS to guest VMs. The databases inside it (Postgres, MariaDB, SQLite) are owned and written to by containers running on the **media VM (VMID 102)**.
- From turtle's perspective, `appdata/` is just files on disk — but those files are being actively written to 24/7 by containers on the media VM over NFS.
- **Strategy for appdata:** shut down the media VM cleanly before the backup window, run restic on turtle, then start the VM again. This gives us consistent, zero-risk file copies without needing pg_dump or any cross-VM SSH trickery.
- **`/mnt/disk1/media/` is also NFS-served** to the media VM (jellyfin, immich uploads land in `media/photos/`) and to `llm.reliyya.xyz` (auto-shutdown at 23:00 daily). The weekly media backup runs **with the media VM running** — accepted risk: media files are plain files, not databases. A photo uploaded mid-backup is either captured complete or skipped and picked up next week; no corruption risk like with live DB files.
- **pve-neo is a legacy host** — pruned to a single latest dump per VM, no new backups arrive. The folder stays in the backup loop (cheap once pruned).
- **mailcow** is no longer backed up via turtle. `petarcubela` backs up directly to the Hetzner Storage Box (`backups/petarcubela`). See the petarcubela backup doc for details.

```
Daily:
  02:00 — pve-host-backup.sh  (PVE host config → /mnt/ssd/pve-turtle/host-config)
        — shut down media VM (102)
           ↓
  02:05 — restic backup on turtle (appdata/ now cold, safe to copy)
           ↓
  ~02:25 — media VM back up
           ↓
  02:30 — backup-restic.sh (projects, pve dirs → local; appdata+projects → Hetzner)

Weekly (Sunday):
  04:00 — backup-media-weekly.sh (disk1/media/ → local + Hetzner)
          media VM stays up — acceptable for plain media files (see above)
          llm host is already down (auto-shutdown 23:00)
```

---

## NFS and SMB shares on turtle

Understanding what is served where matters for backup scope:

|Export|Served to|Notes|
|---|---|---|
|`/mnt/ssd/appdata`|`fde4:ed21:b2c0:5601::/64` (SERVER VLAN)|All container appdata — written to 24/7 by media VM|
|`/mnt/disk1/media`|`fde4:ed21:b2c0:5601::/64` + `5608::/64`|Media VM (jellyfin, immich uploads) + llm host (auto-off 23:00) + DARK VLAN|
|`/mnt/ssd/projects`|`10.56.2.1/28`|SMB share + NFS|
|`/mnt/ssd/k8s/dev`|`10.56.0.48/29`|k8s dev configs|
|`/mnt/ssd/pve-neo`|`fde4:ed21:b2c0:5600::1`|**Legacy** — neo retired; one latest dump per VM kept|

SMB shares: `ISOs` (`disk1/isos`), `projects` (`ssd/projects`), `paperless` (`appdata/apps/paperless_consume`).

The `paperless_consume` SMB share is an **ingestion inbox** — documents placed there by users or scanners are picked up by paperless-ngx and then moved/deleted. Any file sitting there at backup time is unprocessed and would be lost if not backed up. It is covered by the `appdata/` backup (the whole tree is included).

---

## What turtle backs up

|Source|Method|Schedule|
|---|---|---|
|PVE host config (`/mnt/ssd/pve-turtle/host-config`)|`pve-host-backup.sh` tar.gz|Daily 02:00|
|`/mnt/ssd/appdata/` (incl. `paperless_consume`)|restic (VM shut down)|Daily 02:00|
|`/mnt/ssd/projects/`|restic|Daily 02:30|
|`/mnt/ssd/pve-*/dump/`|restic|Daily 02:30|
|`/mnt/disk1/media/` (NFS-live, accepted)|restic|Weekly Sunday 04:00|

**Not handled here** (out of scope for turtle's backup):

- `llm.reliyya.xyz` — separate host, needs its own backup plan
- `petarcubela` VPS — backs up directly to Hetzner Storage Box (`backups/petarcubela`); see petarcubela backup doc
- `cloud` VPS — mostly stateless; worth a restic job later

---

## Hetzner Storage Box setup

### 1. Order

Order a **BX11** (1 TB, ~€3.45/mo) from [robot.hetzner.com](https://robot.hetzner.com/). Your credentials will be `uXXXXXX` — replace every occurrence of `u123456` below.

### 2. SSH key (run as root on turtle)

```bash
ssh-keygen -t ed25519 -f /root/.ssh/hetzner_storagebox -C "turtle-restic" -N ""

# Hetzner's install-ssh-key mechanism (note port 23)
ssh-copy-id -p 23 -i /root/.ssh/hetzner_storagebox.pub \
  u123456@u123456.your-storagebox.de
```

### 3. `/root/.ssh/config` entry

```
Host hetzner-box
  HostName u123456.your-storagebox.de
  User u123456
  Port 23
  IdentityFile /root/.ssh/hetzner_storagebox
  StrictHostKeyChecking accept-new
  # Keepalives for long transfers
  ServerAliveInterval 60
  ServerAliveCountMax 3
  # CRITICAL on DS-Lite WAN: force IPv6. The IPv4 path goes through the ISP's
  # AFTR/CGNAT tunnel (gif0, MTU 1280), which resets long high-throughput TCP
  # sessions after a few minutes ("Broken pipe" mid-upload). Native IPv6
  # bypasses DS-Lite entirely. Hetzner Storage Boxes are IPv6-reachable.
  AddressFamily inet6
```

Verify the v6 path is used: `ssh -v hetzner-box exit 2>&1 | grep Connecting` — the address shown must be IPv6.

Test connectivity: `sftp hetzner-box` — you should get an SFTP prompt.

### 4. Create remote directory

```bash
echo "mkdir backups" | sftp hetzner-box
echo "mkdir backups/turtle" | sftp hetzner-box
```

---

## restic setup

### Install

```bash
apt install restic
restic self-update   # apt version on Debian 12 is 0.15; self-update gets current release
```

### Password file

```bash
echo "your-strong-passphrase" > /root/.restic-password
chmod 600 /root/.restic-password
# Also store this passphrase in your password manager.
# Without it the backup is completely unrecoverable.
```

### Initialise repositories

```bash
restic -r /mnt/disk1/restic-repo \
  --password-file /root/.restic-password init

# --copy-chunker-params ensures the remote repo uses the same chunking as the
# local repo — required for restic copy to deduplicate correctly across repos.
# If you already ran init without this flag, re-create the remote repo:
#   delete backups/turtle on the storage box, mkdir it again, then run this.
restic -r sftp:hetzner-box:backups/turtle \
  --password-file /root/.restic-password \
  init --copy-chunker-params --from-repo /mnt/disk1/restic-repo
```

> **Pitfall:** the SFTP path must be **relative** (no leading slash). `sftp:hetzner-box:backups/turtle` works. `sftp:hetzner-box:/backups/turtle` produces a misleading `MkdirAll ... SSH_FX_FAILURE` error even when the directory exists.

> **Pitfall:** `restic copy` is **destination-centric** — `-r` is the destination repo, `--from-repo` is the source. The flag `--to` does not exist. The correct form is:
> 
> ```bash
> restic -r <destination> --password-file <pw> copy \
>   --from-repo <source> --from-password-file <pw>
> ```

---

## Scripts

### `/usr/local/sbin/pve-host-backup.sh`

Backs up critical PVE host configuration files to a timestamped tar.gz archive. The destination (`/mnt/ssd/pve-turtle/host-config`) sits inside the `pve-turtle/` directory tree, which is picked up by `backup-restic.sh` — so host configs flow into restic and out to Hetzner automatically without any extra backup target.

The script is generic and already in use across multiple PVE hosts. On turtle, invoke it with:

```bash
pve-host-backup.sh --dest /mnt/ssd/pve-turtle/host-config
```

Sources backed up: `/etc/pve` (VM/CT configs, storage defs, firewall rules, user permissions), network interfaces, fstab, cron jobs, apt sources, SSH config, sysctl, modprobe/modules-load (IOMMU/VFIO settings), systemd units, and root's authorized_keys.

Install the script:

```bash
install -o root -g root -m 755 pve-host-backup.sh /usr/local/sbin/pve-host-backup.sh
```

---

### `/usr/local/bin/backup-appdata.sh`

Shuts down the media VM cleanly, runs restic on `appdata/`, restarts the VM. All containers on the media VM (immich, paperless, gitea, jellyfin, karakeep) stop as part of the VM shutdown — no separate container management needed.

Runs in parallel with `pve-host-backup.sh` at 02:00 (they touch different paths and do not interfere).

```bash
#!/usr/bin/env bash
# backup-appdata.sh
# Shuts down media VM (102), backs up appdata/ via restic, restarts VM.
# Runs at 02:00 daily via /etc/cron.d/turtle-backup.
set -euo pipefail

LOG="/var/log/turtle-backup.log"
TS=$(date +%Y%m%d-%H%M%S)
PW_FILE="/root/.restic-password"
LOCAL_REPO="/mnt/disk1/restic-repo"
MEDIA_VMID=102
SHUTDOWN_TIMEOUT=120   # seconds to wait for clean shutdown

# All output (incl. restic's and qm's) to log + console
exec > >(tee -a "$LOG") 2>&1

log() { echo "[${TS}] $*"; }

log "=== appdata backup starting ==="

# ── Shutdown ──────────────────────────────────────────────────────────────────
VM_STATUS=$(qm status "$MEDIA_VMID" | awk '{print $2}')

if [[ "$VM_STATUS" == "running" ]]; then
  log "Shutting down media VM ($MEDIA_VMID)"
  qm shutdown "$MEDIA_VMID" --timeout "$SHUTDOWN_TIMEOUT"

  # Poll until stopped
  WAITED=0
  while [[ "$(qm status "$MEDIA_VMID" | awk '{print $2}')" != "stopped" ]]; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [[ $WAITED -ge $((SHUTDOWN_TIMEOUT + 30)) ]]; then
      log "ERROR: media VM did not stop within timeout — aborting, not touching files"
      exit 1
    fi
  done
  log "Media VM stopped after ${WAITED}s"
else
  log "Media VM already stopped — proceeding"
fi

# ── restic backup ─────────────────────────────────────────────────────────────
log "Backing up appdata/"

restic -r "$LOCAL_REPO" --password-file "$PW_FILE" backup \
  /mnt/ssd/appdata \
  --tag appdata --tag turtle \
  --exclude "/mnt/ssd/appdata/apps/ollama/models" \
  --exclude "/mnt/ssd/appdata/apps/jellyfin/cache" \
  --exclude "/mnt/ssd/appdata/apps/open-webui/cache" \
  --exclude "/mnt/ssd/appdata/apps/paperless_data/index" \
  --exclude "lost+found" \
  --exclude "*.tmp" \
  && log "appdata restic backup OK" \
  || {
    log "ERROR: appdata restic backup failed — starting VM anyway"
    qm start "$MEDIA_VMID"
    exit 1
  }

# ── Restart VM ────────────────────────────────────────────────────────────────
log "Starting media VM ($MEDIA_VMID)"
qm start "$MEDIA_VMID"
log "Media VM started"

log "=== appdata backup complete ==="
```

---

### `/usr/local/bin/backup-restic.sh`

Backs up projects and all `pve-*/` directories (dumps + host configs) to the local repo, then copies only the non-pve snapshots to Hetzner.

**Why pve dumps are local-only on Hetzner:** the `.vma.zst` files vzdump produces are already fully compressed. restic cannot deduplicate them — every daily snapshot is a full re-upload of 251 GiB. Keeping 7 daily copies offsite would consume ~400-500 GiB of the Hetzner quota alone, crowding out everything else. The local restic repo on `disk1` (backed by SnapRAID parity) is sufficient protection for pve dumps. They are recoverable locally; the offsite tier is reserved for data that cannot be re-created.

```bash
#!/usr/bin/env bash
# backup-restic.sh
# Backs up projects + pve dirs to local repo; copies appdata+projects to Hetzner.
# pve dumps stay LOCAL ONLY — pre-compressed, no restic dedup benefit offsite.
# Runs at 02:30 daily — appdata backup above finishes well within 30 min.
set -euo pipefail

LOG="/var/log/turtle-backup.log"
TS=$(date +%Y%m%d-%H%M%S)
PW_FILE="/root/.restic-password"
LOCAL_REPO="/mnt/disk1/restic-repo"
REMOTE_REPO="sftp:hetzner-box:backups/turtle"

# Send ALL output (including restic's own stdout/stderr) to the log AND console.
# Without this, restic errors are invisible under cron.
exec > >(tee -a "$LOG") 2>&1

log() { echo "[${TS}] $*"; }

restic_local()  { restic -r "$LOCAL_REPO"  --password-file "$PW_FILE" "$@"; }
restic_remote() { restic -r "$REMOTE_REPO" --password-file "$PW_FILE" "$@"; }

# Retry wrapper for restic copy — copy is idempotent and resumable, so on a
# flaky connection simply re-invoking continues from the last completed pack.
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
    log "WARN: copy --tag $tag failed (attempt $i), retrying in 60s"
    sleep 60
  done
  log "ERROR: copy --tag $tag failed after $attempts attempts"
  return 1
}

log "=== restic daily backup starting ==="

# ── Projects ──────────────────────────────────────────────────────────────────
log "Backing up projects"
restic_local backup \
  /mnt/ssd/projects \
  --tag projects --tag turtle \
  --exclude "lost+found"

# ── Proxmox: vzdump outputs + host config archives ────────────────────────────
# pve-*/dump/       — compressed VM/CT backups (.vma.zst/.tar.zst) — LOCAL ONLY
# pve-*/host-config — tar.gz archives from pve-host-backup.sh — also to Hetzner
# pve-neo is legacy (retired host): holds one latest dump per VM, no new writes.
# Tagged separately so the copy step can filter by tag.
log "Backing up pve directories (dumps + host configs)"
for pve_dir in \
  /mnt/ssd/pve-neo \
  /mnt/ssd/pve-turtle \
  /mnt/ssd/pve-hetzner; do
  if [[ -d "$pve_dir" ]]; then
    restic_local backup "$pve_dir" \
      --tag pve --tag turtle \
      && log "  OK: $pve_dir" \
      || log "  WARN: $pve_dir failed (non-fatal)"
  fi
done

# ── Prune local repo ──────────────────────────────────────────────────────────
log "Pruning local repo"
restic_local forget \
  --keep-daily   7 \
  --keep-weekly  4 \
  --keep-monthly 6 \
  --prune

# ── Copy to Hetzner — appdata and projects snapshots only ─────────────────────
# pve snapshots are excluded (local only). Retried automatically on failure.
copy_to_remote appdata
copy_to_remote projects

# ── Prune remote ──────────────────────────────────────────────────────────────
log "Pruning Hetzner repo"
restic_remote forget \
  --keep-daily   7 \
  --keep-weekly  4 \
  --keep-monthly 12 \
  --prune

log "=== restic daily backup complete ==="
```

---

### `/usr/local/bin/backup-media-weekly.sh`

`disk1/media/` is NFS-served to the media VM (jellyfin reads, immich writes uploads into `media/photos/`) and to the llm host (already off — auto-shutdown at 23:00). The backup runs **with the media VM up**. This is safe for plain media files: restic snapshots a file either complete or not at all, and a photo mid-upload at 04:00 Sunday is simply captured next week. The consistency concerns that force a VM shutdown for `appdata/` (live database files) do not apply here.

```bash
#!/usr/bin/env bash
# backup-media-weekly.sh — weekly restic backup of disk1/media/
# Runs Sunday 04:00 via /etc/cron.d/turtle-backup.
set -euo pipefail

LOG="/var/log/turtle-backup.log"
TS=$(date +%Y%m%d-%H%M%S)
PW_FILE="/root/.restic-password"
LOCAL_REPO="/mnt/disk1/restic-repo"
REMOTE_REPO="sftp:hetzner-box:backups/turtle"

# All output (incl. restic's) to log + console
exec > >(tee -a "$LOG") 2>&1

log() { echo "[${TS}] $*"; }

log "=== Weekly media backup starting ==="

# Local backup — full media tree including immich thumbs (fast local restore)
restic -r "$LOCAL_REPO" --password-file "$PW_FILE" backup \
  /mnt/disk1/media \
  --tag media --tag turtle \
  --exclude "/mnt/disk1/media/downloads" \
  --exclude "lost+found"

restic -r "$LOCAL_REPO" --password-file "$PW_FILE" forget \
  --tag media \
  --keep-weekly  8 \
  --keep-monthly 12 \
  --prune

# Remote copy to Hetzner — retried; restic copy resumes from completed packs
ATTEMPTS=5
for ((i=1; i<=ATTEMPTS; i++)); do
  log "Copying media snapshots to Hetzner (attempt $i/$ATTEMPTS)"
  if restic -r "$REMOTE_REPO" --password-file "$PW_FILE" copy \
       --from-repo "$LOCAL_REPO" \
       --from-password-file "$PW_FILE" \
       --tag media; then
    log "Media copy OK"
    break
  fi
  if (( i == ATTEMPTS )); then
    log "ERROR: media copy failed after $ATTEMPTS attempts"
    exit 1
  fi
  log "WARN: media copy failed (attempt $i), retrying in 120s"
  sleep 120
done

restic -r "$REMOTE_REPO" --password-file "$PW_FILE" forget \
  --tag media \
  --keep-weekly  4 \
  --keep-monthly 6 \
  --prune

log "=== Weekly media backup complete ==="
```

---

## Cron schedule

`/etc/cron.d/turtle-backup`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 02:00 — PVE host config backup (tar.gz to /mnt/ssd/pve-turtle/host-config)
0   2  * * *  root  /usr/local/sbin/pve-host-backup.sh --dest /mnt/ssd/pve-turtle/host-config

# 02:00 — shut down media VM (102), back up appdata/, restart VM
#         runs in parallel with pve-host-backup.sh — different paths, no conflict
0   2  * * *  root  /usr/local/bin/backup-appdata.sh

# 02:30 — back up projects + pve dirs; copy appdata+projects to Hetzner
#         30 min gap ensures both 02:00 jobs are done before this runs
30  2  * * *  root  /usr/local/bin/backup-restic.sh

# 04:00 Sunday — large media backup (weekly, no VM shutdown needed)
0   4  * * 0  root  /usr/local/bin/backup-media-weekly.sh
```

---

## Storage capacity analysis

Based on current disk usage (`du` as of 2026-06-10):

|Source|Size|Local|Hetzner|
|---|---|---|---|
|appdata (excl. ollama)|~6 GiB|✓ daily|✓ daily (high dedup)|
|appdata/databases|~0.9 GiB|✓ daily|✓ daily|
|projects (grapheneos removed)|~7 GiB|✓ daily|✓ daily|
|pve-turtle/dump|~119 GiB|✓ daily|**✗ local only**|
|pve-neo/dump (pruned to latest per VM)|~20–45 GiB|✓ daily|**✗ local only**|
|pve-hetzner/dump|~42 GiB|✓ daily|**✗ local only**|
|media/videos|~279 GiB|✓ weekly|✓ weekly|
|media/photos (immich writes here via NFS)|~62 GiB|✓ weekly|✓ weekly|
|media/books|~13 GiB|✓ weekly|✓ weekly|
|media/other|~8 GiB|✓ weekly|✓ weekly|
|media/documents|~3.9 GiB|✓ weekly|✓ weekly|
|ollama/models|~51 GiB|**✗ excluded**|**✗ excluded**|

**Local repo (`disk1`):** disk1 has ~2.6 TiB free. The local repo will reach ~800 GiB–1 TiB at steady state with full retention. No capacity concern.

**Hetzner BX11 (1 TB usable ~930 GiB):**

|Category|Estimated offsite usage|
|---|---|
|appdata (7d/4w/12m, ~70% dedup)|~10–20 GiB|
|projects (7d/4w/12m, ~50% dedup)|~20–40 GiB|
|media/photos (4w/6m, low churn)|~65–75 GiB|
|media/videos (4w/6m, slow change)|~290–310 GiB|
|media/other (books, music, etc.)|~25–30 GiB|
|pve dumps|0 GiB (local only)|
|**Total estimate**|**~410–475 GiB**|

The BX11 fits comfortably with the pve-dumps-local-only strategy, leaving ~450–520 GiB of headroom. As your video library grows this remains manageable for 2–3 years. Upgrade to **BX21 (2 TB, ~€6.90/mo)** when usage exceeds 700 GiB.

---

## Retention summary

|Scope|Local (disk1)|Hetzner|
|---|---|---|
|appdata|7 daily, 4 weekly, 6 monthly|7 daily, 4 weekly, 12 monthly|
|projects|7 daily, 4 weekly, 6 monthly|7 daily, 4 weekly, 12 monthly|
|pve dumps + host configs|7 daily, 4 weekly, 6 monthly|**local only**|
|media|8 weekly, 12 monthly|4 weekly, 6 monthly|
|pve host config raw tar.gz|14 days (`--retention` flag)|covered by restic above|

---

## Intentional exclusions

|Path|Reason|
|---|---|
|`appdata/apps/ollama/models/`|Re-downloadable; large; lives primarily on llm host|
|`appdata/apps/jellyfin/cache/`|Regenerated on startup|
|`appdata/apps/open-webui/cache/`|Regenerated on startup|
|`appdata/apps/paperless_data/index/`|Whoosh search index; rebuilt from DB|
|`disk1/media/downloads/`|Transient staging|
|`disk1/archives/`|**Delete immediately** — old tar.xz files, replaced by restic|
|`disk1/mailcow-backup/`|Retired — petarcubela backs up directly to Hetzner|
|pve dump files (Hetzner only)|Pre-compressed, no dedup benefit; local copy sufficient|
|VM/LXC raw disk images|vzdump handles this; only vzdump output is restic'd|

---

## Migration steps (one-time)

```bash
# 1. DELETE old tar archives — 115 GiB of redundant data, do this first
#    This also removes them from the next restic backup run
rm -rf /mnt/disk1/archives
# Verify:
ls /mnt/disk1/

# 2. Prune legacy pve-neo dumps — keep only the newest dump per VM
rm -f /mnt/ssd/pve-neo/dump/*.tmp
# Dry run — lists what WOULD be deleted (everything except newest per VMID):
for vmid in $(ls /mnt/ssd/pve-neo/dump/vzdump-*-*.vma.zst 2>/dev/null \
              | sed -E 's/.*vzdump-(qemu|lxc)-([0-9]+)-.*/\2/' | sort -u); do
  ls -t /mnt/ssd/pve-neo/dump/vzdump-*-${vmid}-*.vma.zst | tail -n +2
done
# If the list looks right, delete (incl. matching .log/.notes):
for vmid in $(ls /mnt/ssd/pve-neo/dump/vzdump-*-*.vma.zst 2>/dev/null \
              | sed -E 's/.*vzdump-(qemu|lxc)-([0-9]+)-.*/\2/' | sort -u); do
  ls -t /mnt/ssd/pve-neo/dump/vzdump-*-${vmid}-*.vma.zst | tail -n +2 | while read f; do
    rm -fv "$f" "${f%.vma.zst}.log" "${f%.vma.zst}.notes" 2>/dev/null
  done
done
du -sh /mnt/ssd/pve-neo/

# 3. Retire mailcow-backup/ once petarcubela is confirmed backing up to Hetzner
#    Until then, leave it — removing is irreversible.
#    When ready:
rm -rf /mnt/disk1/mailcow-backup

# 4. Remove any old cron entries that produced the tar archives
crontab -l   # check for old backup jobs
```

---

## First backup run (manual)

Run the cycle once by hand before enabling cron. Order matters — cleanup first, then the daily chain, then media:

```bash
# 0. Prerequisites done: repos initialised, scripts installed, migration steps 1+2 run

# 1. Daily chain (shuts down media VM for ~20 min)
/usr/local/sbin/pve-host-backup.sh --dest /mnt/ssd/pve-turtle/host-config
/usr/local/bin/backup-appdata.sh
/usr/local/bin/backup-restic.sh

# 2. Media (can run any time; first Hetzner upload of ~360 GiB takes many hours —
#    start it in tmux/screen so an SSH disconnect doesn't kill it)
tmux new -s mediabackup
/usr/local/bin/backup-media-weekly.sh
# detach: Ctrl-B D — reattach later: tmux attach -t mediabackup

# 3. Verify
tail -50 /var/log/turtle-backup.log
restic -r /mnt/disk1/restic-repo --password-file /root/.restic-password snapshots
restic -r sftp:hetzner-box:backups/turtle --password-file /root/.restic-password snapshots

# 4. If all clean: install /etc/cron.d/turtle-backup
```

---

## Verification commands

```bash
# Check local repo integrity (run weekly or after any incident)
restic -r /mnt/disk1/restic-repo --password-file /root/.restic-password check

# List all snapshots with tags
restic -r /mnt/disk1/restic-repo --password-file /root/.restic-password snapshots

# List files in latest appdata snapshot
restic -r /mnt/disk1/restic-repo --password-file /root/.restic-password \
  ls latest --tag appdata

# Test restore of projects to a temp location
restic -r /mnt/disk1/restic-repo --password-file /root/.restic-password \
  restore latest --tag projects --target /mnt/ssd/tmp/restore-test

# Verify Hetzner repo and its snapshots
restic -r sftp:hetzner-box:backups/turtle \
  --password-file /root/.restic-password snapshots

# Check Hetzner repo only has appdata+projects+media (no pve dumps)
restic -r sftp:hetzner-box:backups/turtle \
  --password-file /root/.restic-password snapshots --json \
  | python3 -c "import sys,json; [print(s['tags'], s['id'][:8]) for s in json.load(sys.stdin)]"

# Check pve host config archives are being created
ls -lht /mnt/ssd/pve-turtle/host-config/

# Manual run of full daily cycle (will shut down media VM)
/usr/local/sbin/pve-host-backup.sh --dest /mnt/ssd/pve-turtle/host-config \
  && /usr/local/bin/backup-appdata.sh \
  && /usr/local/bin/backup-restic.sh
```

---

## First-run checklist

1. `apt install restic && restic self-update`
2. Create `/root/.restic-password` (save passphrase in password manager too)
3. Set up Hetzner Storage Box SSH key and `~/.ssh/config` entry
4. `restic init` local repo; init remote with `--copy-chunker-params --from-repo` and `--from-password-file` (see Initialise repositories section above)
5. **Delete `/mnt/disk1/archives/`** (115 GiB, do before first backup run)
6. Install `pve-host-backup.sh` to `/usr/local/sbin/`
7. Install `backup-appdata.sh`, `backup-restic.sh`, `backup-media-weekly.sh` to `/usr/local/bin/` and `chmod +x` all four
8. Do a manual first run — initial Hetzner upload (~400–475 GiB) will take hours; run when you don't need the uplink
9. Install `/etc/cron.d/turtle-backup`
10. Confirm petarcubela is backing up to Hetzner, then retire `mailcow-backup/`
11. Check `/var/log/turtle-backup.log` the next morning

---

## Out of scope — future backup topics

|Host|Status|Notes|
|---|---|---|
|`llm.reliyya.xyz`|Not covered|GPU bare-metal; its appdata/ is NFS-served from turtle so the appdata backup covers it; ollama models excluded by choice|
|`petarcubela` VPS|Separate doc|Backs up mailcow directly to `sftp:hetzner-box:backups/petarcubela`; git repos need their own strategy|
|`cloud` VPS|Not covered|Mostly stateless; worth a small restic job once Hetzner box is confirmed working|
|`ad` VM (lldap)|Covered|lldap data is in `appdata/idm/lldap_data/` — covered by appdata backup and vzdump|