# petarcubela — Mailcow Backup Strategy

## Architecture context

- **petarcubela** (`mail.petarcubela.de`) is a VPS running mailcow-dockerized.
- Mailcow's own backup script runs daily at 06:25 via `/etc/cron.daily/mailcow-backup`, producing a new `mailcow-YYYY-MM-DD-HH-MM-SS/` directory under `/opt/backup/` containing seven files including `mailcow.conf` (owned by root, mode 600).
- restic runs as root immediately after mailcow finishes, backing up `/opt/backup/` to the Hetzner Storage Box (`backups/petarcubela`).
- The existing `--delete-days 10` option in the mailcow cron keeps only 10 days of raw backup dirs locally. restic handles long-term retention on Hetzner.

```
06:25 — mailcow backup_and_restore.sh  (/opt/backup/mailcow-YYYY-MM-DD-…/)
         ↓  (completes in ~10 min depending on vmail size)
07:00 — restic backup                  (backups/petarcubela on Hetzner)
         ↓
07:30 — restic forget + prune          (enforce retention, free space on Hetzner)
```

---

## Hetzner Storage Box — petarcubela directory

The Storage Box is already set up for turtle. petarcubela gets its own subdirectory and its own restic repository — completely independent of turtle's.

```bash
# From turtle or any host with the hetzner-box SSH alias already configured:
echo "mkdir backups/petarcubela" | sftp hetzner-box
```

Or directly from petarcubela once the SSH key is installed (see below):

```bash
echo "mkdir backups/petarcubela" | sftp -P 23 u123456@u123456.your-storagebox.de
```

---

## Setup on petarcubela

All commands run as **root** on `mail.petarcubela.de`.

### 1. Install restic

```bash
apt install restic
restic self-update   # get 0.16+ for correct copy/forget behaviour
```

### 2. Generate a dedicated SSH key for the Storage Box

```bash
ssh-keygen -t ed25519 -f /root/.ssh/hetzner_storagebox -C "petarcubela-restic" -N ""

# Install the public key on the Storage Box (Hetzner's mechanism, port 23)
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
```

Test: `sftp hetzner-box` — you should get an SFTP prompt.

### 4. Password file

Use the **same passphrase** as turtle's restic repo:

```bash
echo "your-shared-passphrase" > /root/.restic-password
chmod 600 /root/.restic-password
```

### 5. Initialise the repository

```bash
restic -r sftp:hetzner-box:backups/petarcubela \
  --password-file /root/.restic-password init
```

> **Pitfall:** path must be relative — no leading slash. `sftp:hetzner-box:backups/petarcubela` works. `sftp:hetzner-box:/backups/petarcubela` produces a misleading `MkdirAll … SSH_FX_FAILURE` error even when the directory exists.

---

## Script

### `/usr/local/bin/backup-mailcow-restic.sh`

Backs up `/opt/backup/` to Hetzner, then prunes old snapshots. `mailcow.conf` is owned root:root mode 600 — running restic as root means it is captured correctly without any workarounds.

```bash
#!/usr/bin/env bash
# backup-mailcow-restic.sh
# Backs up /opt/backup/ (mailcow dumps) to Hetzner Storage Box via restic.
# Runs at 07:00 daily via /etc/cron.d/petarcubela-backup — after the
# mailcow backup_and_restore.sh job finishes (~06:25 + ~10-15 min).
set -euo pipefail

LOG="/var/log/petarcubela-backup.log"
TS=$(date +%Y%m%d-%H%M%S)
PW_FILE="/root/.restic-password"
REMOTE_REPO="sftp:hetzner-box:backups/petarcubela"

log() { echo "[${TS}] $*" | tee -a "$LOG"; }

log "=== mailcow restic backup starting ==="

# ── Backup /opt/backup/ ───────────────────────────────────────────────────────
# This tree contains only mailcow-YYYY-MM-DD-*/ directories; nothing to exclude.
# restic deduplicates across daily snapshots well — backup_vmail.tar.gz chunks
# that haven't changed (e.g. unchanged mailboxes) are not re-uploaded.
restic -r "$REMOTE_REPO" --password-file "$PW_FILE" backup \
  /opt/backup \
  --tag mailcow --tag petarcubela \
  && log "Backup OK" \
  || { log "ERROR: restic backup failed"; exit 1; }

# ── Prune ─────────────────────────────────────────────────────────────────────
# Keep more history than the local mailcow --delete-days 10.
# Local raw dirs: 10 days (controlled by mailcow cron --delete-days option).
# Hetzner restic: 14 daily, 8 weekly, 12 monthly.
log "Pruning Hetzner repo"
restic -r "$REMOTE_REPO" --password-file "$PW_FILE" forget \
  --keep-daily   14 \
  --keep-weekly   8 \
  --keep-monthly 12 \
  --prune

log "=== mailcow restic backup complete ==="
```

Install and make executable:

```bash
install -o root -g root -m 755 \
  backup-mailcow-restic.sh /usr/local/bin/backup-mailcow-restic.sh
```

---

## Cron schedule

`/etc/cron.d/petarcubela-backup`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 07:00 — restic backup of mailcow dumps to Hetzner
# Runs after /etc/cron.daily/mailcow-backup (06:25, takes ~10-15 min)
0  7  * * *  root  /usr/local/bin/backup-mailcow-restic.sh
```

> **Note on timing:** `/etc/cron.daily/` jobs are dispatched by `cron` (or `anacron`) at a fixed time configured in `/etc/crontab` or `/etc/anacrontab`. On a VPS without anacron the default is typically 06:25. Verify with `grep -r cron.daily /etc/crontab /etc/anacrontab 2>/dev/null` and adjust the 07:00 start time above if the mailcow job runs later.

---

## Retention summary

|Layer|Retention|Controlled by|
|---|---|---|
|Raw `mailcow-*/` dirs on petarcubela|10 days|mailcow cron `--delete-days 10`|
|restic snapshots on Hetzner|14 daily, 8 weekly, 12 monthly|`backup-mailcow-restic.sh` forget|

---

## Verification commands

```bash
# List snapshots on Hetzner
restic -r sftp:hetzner-box:backups/petarcubela \
  --password-file /root/.restic-password snapshots

# Check repo integrity
restic -r sftp:hetzner-box:backups/petarcubela \
  --password-file /root/.restic-password check

# List files in latest snapshot
restic -r sftp:hetzner-box:backups/petarcubela \
  --password-file /root/.restic-password ls latest

# Test restore of a specific backup dir to /tmp
restic -r sftp:hetzner-box:backups/petarcubela \
  --password-file /root/.restic-password \
  restore latest --target /tmp/mailcow-restore-test

ls /tmp/mailcow-restore-test/opt/backup/
```

---

## First-run checklist

1. `apt install restic && restic self-update`
2. Generate `/root/.ssh/hetzner_storagebox` and install public key on Storage Box
3. Add `hetzner-box` entry to `/root/.ssh/config`
4. Create `/root/.restic-password` with the shared passphrase
5. Create `backups/petarcubela` directory on the Storage Box via sftp
6. `restic init` the remote repo
7. Install script to `/usr/local/bin/` and `chmod +x`
8. Run manually once to confirm: `/usr/local/bin/backup-mailcow-restic.sh`
9. Check `/var/log/petarcubela-backup.log`
10. Install `/etc/cron.d/petarcubela-backup`
11. After two days of clean runs, confirm snapshots on Hetzner, then:
    - Delete `/mnt/disk1/mailcow-backup/` on turtle
    - Remove any rsync cron entries on petarcubela or turtle related to mailcow

---

## Retiring the old turtle mailcow-backup directory

Once you have confirmed restic is running cleanly on petarcubela (check `restic snapshots` shows at least two daily snapshots and `restic check` passes):

```bash
# On turtle — remove the old pulled backup directory
rm -rf /mnt/disk1/mailcow-backup

# Verify nothing in the turtle restic cron still references it
grep -r mailcow /etc/cron.d/ /usr/local/bin/
```