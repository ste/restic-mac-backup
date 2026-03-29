#!/bin/bash
# restic-laptop-backup.sh
# Backs up ~ to a NAS/server via SFTP (hourly), with optional B2 offsite (daily).
# Designed for macOS laptops, triggered by launchd.
#
# See README.md for setup instructions.

set -euo pipefail

# ============================================================
# Configuration — edit these to match your setup
# ============================================================
NAS_REPO="sftp:nas-restic:/path/to/restic-repo"       # SSH config host + repo path
B2_REPO=""                                              # e.g. "b2:my-backup-bucket" (leave empty to skip)
EXCLUDE_FILE="$HOME/.restic-laptop-backup-excludes"
LOCK_FILE="/tmp/restic-laptop-backup.lock"
LOG_FILE="$HOME/.restic-laptop-backup.log"

# ============================================================
# Options
# ============================================================
FORCE_DAILY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-daily) FORCE_DAILY=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================
# Logging
# ============================================================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# ============================================================
# Precondition checks
# ============================================================

# 1. Is another backup already running?
if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(cat "$LOCK_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        log "SKIP: backup already running (PID $existing_pid)"
        exit 0
    else
        log "WARN: stale lock file found (PID $existing_pid), removing"
        rm -f "$LOCK_FILE"
    fi
fi

# 2. Are we on AC power?
if ! pmset -g batt | grep -q "AC Power"; then
    log "SKIP: not on AC power"
    exit 0
fi

# 3. Is the NAS/server reachable?
#    Extract the hostname from your SSH config alias.
#    Update the host and port below to match your setup.
NAS_HOST="your-nas-hostname"   # e.g. nas.local, 192.168.1.100
NAS_PORT=22
if ! nc -z -w 2 "$NAS_HOST" "$NAS_PORT" >/dev/null 2>&1; then
    log "SKIP: NAS not reachable"
    exit 0
fi

# ============================================================
# Set up lock file and clean up on exit
# ============================================================
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ============================================================
# NAS backup (every run — hourly via launchd)
# ============================================================
export RESTIC_PASSWORD=$(security find-generic-password -a restic -s restic-nas-repo -w)

log "START: NAS backup beginning"

# restic exit codes:
#   0 = success
#   1 = fatal error, no snapshot created
#   3 = snapshot created but some files could not be read (e.g. macOS TCC permissions)
set +e
restic backup "$HOME" \
    --repo "$NAS_REPO" \
    --exclude-file="$EXCLUDE_FILE" \
    --verbose \
    >> "$LOG_FILE" 2>&1
nas_exit_code=$?
set -e

case $nas_exit_code in
    0) log "OK: NAS backup completed successfully" ;;
    3) log "WARN: NAS backup completed with warnings (some files could not be read)" ;;
    *) log "ERROR: NAS backup failed with exit code $nas_exit_code" ;;
esac

# ============================================================
# Daily tasks (runs once every 20+ hours, or when --force-daily)
# ============================================================
DAILY_STAMP="$HOME/.restic-laptop-backup-daily-stamp"
hours_since_daily=999
if [ -f "$DAILY_STAMP" ]; then
    last_daily=$(cat "$DAILY_STAMP")
    now=$(date +%s)
    hours_since_daily=$(( (now - last_daily) / 3600 ))
fi

if [ "$hours_since_daily" -ge 20 ] || [ "$FORCE_DAILY" = true ]; then
    date +%s > "$DAILY_STAMP"

    # --- B2 offsite backup (optional) ---
    if [ -n "$B2_REPO" ]; then
        export B2_ACCOUNT_ID=$(security find-generic-password -a restic -s restic-b2-account-id -w)
        export B2_ACCOUNT_KEY=$(security find-generic-password -a restic -s restic-b2-account-key -w)
        export RESTIC_PASSWORD=$(security find-generic-password -a restic -s restic-b2-repo -w)

        log "START: B2 backup beginning"

        set +e
        restic backup "$HOME" \
            --repo "$B2_REPO" \
            --exclude-file="$EXCLUDE_FILE" \
            --verbose \
            >> "$LOG_FILE" 2>&1
        b2_exit_code=$?
        set -e

        case $b2_exit_code in
            0) log "OK: B2 backup completed successfully" ;;
            3) log "WARN: B2 backup completed with warnings (some files could not be read)" ;;
            *) log "ERROR: B2 backup failed with exit code $b2_exit_code" ;;
        esac
    fi

    # --- NAS retention pruning ---
    export RESTIC_PASSWORD=$(security find-generic-password -a restic -s restic-nas-repo -w)

    log "PRUNE: running NAS retention policy"
    restic forget --repo "$NAS_REPO" \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 12 \
        --prune \
        >> "$LOG_FILE" 2>&1
    log "PRUNE: NAS complete"

    # --- B2 retention pruning (if enabled) ---
    if [ -n "$B2_REPO" ]; then
        export B2_ACCOUNT_ID=$(security find-generic-password -a restic -s restic-b2-account-id -w)
        export B2_ACCOUNT_KEY=$(security find-generic-password -a restic -s restic-b2-account-key -w)
        export RESTIC_PASSWORD=$(security find-generic-password -a restic -s restic-b2-repo -w)

        log "PRUNE: running B2 retention policy"
        restic forget --repo "$B2_REPO" \
            --keep-daily 7 \
            --keep-weekly 4 \
            --keep-monthly 12 \
            --prune \
            >> "$LOG_FILE" 2>&1
        log "PRUNE: B2 complete"
    fi
fi
