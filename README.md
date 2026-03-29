# restic-mac-backup

Automated, hourly backups of your macOS home directory to a NAS (or any SFTP server) using [restic](https://restic.net/). Optionally backs up to Backblaze B2 daily for offsite protection.

Runs via launchd. Skips gracefully when you're on battery or away from your home network.

## What it does

- **Hourly**: backs up `~` to your NAS/server over SFTP
- **Daily** (optional): backs up `~` to Backblaze B2
- **Daily**: prunes old snapshots (keeps 7 daily, 4 weekly, 12 monthly)
- **Skips automatically** when on battery power or the NAS isn't reachable
- **Lock file** prevents overlapping runs
- **Credentials** stored in macOS Keychain (not in config files)

## Files

| File | Description |
|------|-------------|
| `restic-laptop-backup.sh` | The backup script — edit the config section at the top |
| `restic-laptop-backup-excludes` | Exclude patterns — review and uncomment lines for your setup |
| `local.restic-laptop-backup.plist` | launchd plist template — runs the script hourly |

## Setup

### 1. Install restic

```bash
brew install restic
```

### 2. Clone this repo and put the files in place

```bash
git clone https://github.com/ste/restic-mac-backup.git
cd restic-mac-backup

# Copy the backup script
mkdir -p ~/bin
cp restic-laptop-backup.sh ~/bin/
chmod +x ~/bin/restic-laptop-backup.sh

# Copy the excludes file
cp restic-laptop-backup-excludes ~/.restic-laptop-backup-excludes
```

### 3. Edit the excludes file

Open `~/.restic-laptop-backup-excludes` and:

1. Replace every `YOURUSERNAME` with your macOS username
2. Uncomment the lines that apply to your setup
3. Check for large directories you might want to add:

```bash
du -sh ~/Library/Application\ Support/* | sort -rh | head -20
du -sh ~/.* | sort -rh | head -20
```

### 4. Set up your NAS/server

You need an SFTP-accessible server. Any Linux box, NAS (Synology, QNAP, etc.), or server with SSH will work.

**Generate a restricted SSH key:**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_restic_nas -N "" -C "$(hostname)-restic"
```

**Add the public key to your server** with SFTP-only restrictions:

```bash
cat ~/.ssh/id_ed25519_restic_nas.pub
# SSH into your server and add this to ~/.ssh/authorized_keys:
# command="internal-sftp",restrict ssh-ed25519 AAAA...KEY... hostname-restic
```

> The `command="internal-sftp",restrict` prefix locks this key to SFTP only — it can't be used for shell access. Good practice for a backup-only key.

**Add an SSH config entry** in `~/.ssh/config`:

```
Host nas-restic
    HostName your-nas-or-server.local
    User your-username
    IdentityFile ~/.ssh/id_ed25519_restic_nas
    IdentitiesOnly yes
```

**Test the connection:**

```bash
SSH_AUTH_SOCK="" sftp nas-restic
```

This should drop you into an SFTP prompt. Type `quit` to exit.

### 5. Initialise the restic repository on your NAS

```bash
export RESTIC_PASSWORD="your-strong-password-here"
restic init --repo sftp:nas-restic:/path/to/restic-repo
```

Remember this password — you'll need it for every machine you back up and for any future restores. **If you lose it, your backups are unrecoverable.**

### 6. Store the password in Keychain

```bash
security add-generic-password -a restic -s restic-nas-repo -w
# You'll be prompted to enter the password
```

Test retrieval:

```bash
security find-generic-password -a restic -s restic-nas-repo -w
```

### 7. Edit the backup script

Open `~/bin/restic-laptop-backup.sh` and update the configuration section at the top:

```bash
NAS_REPO="sftp:nas-restic:/path/to/restic-repo"   # Must match step 5
NAS_HOST="your-nas-or-server.local"                 # For reachability check
NAS_PORT=22
```

Leave `B2_REPO=""` unless you're setting up offsite backup (see below).

### 8. Test a manual backup

```bash
~/bin/restic-laptop-backup.sh
tail -20 ~/.restic-laptop-backup.log
```

The first run will take a while as restic builds its initial snapshot. Subsequent runs are incremental and fast.

### 9. Grant Full Disk Access to restic

Without this, macOS will block restic from reading some directories and you'll see exit code 3 warnings.

**System Settings → Privacy & Security → Full Disk Access** → add `/opt/homebrew/bin/restic`

(On Intel Macs, the path is `/usr/local/bin/restic`)

### 10. Install the launchd plist

```bash
# Replace HOMEDIR with your actual home directory path
sed "s|HOMEDIR|$HOME|g" local.restic-laptop-backup.plist > ~/Library/LaunchAgents/local.restic-laptop-backup.plist

launchctl load ~/Library/LaunchAgents/local.restic-laptop-backup.plist
```

### 11. Verify it's running

Wait an hour (or reboot — `RunAtLoad` triggers it on login), then:

```bash
tail -20 ~/.restic-laptop-backup.log
```

Check your snapshots:

```bash
export RESTIC_PASSWORD=$(security find-generic-password -a restic -s restic-nas-repo -w)
restic snapshots --repo sftp:nas-restic:/path/to/restic-repo
```

## Multiple Macs

restic handles cross-machine dedup natively. Point a second Mac at the same repo (same password, same SSH setup) and it will share storage efficiently. Each machine's snapshots are tagged with its hostname.

## Restoring files

```bash
export RESTIC_PASSWORD=$(security find-generic-password -a restic -s restic-nas-repo -w)

# List snapshots
restic snapshots --repo sftp:nas-restic:/path/to/restic-repo

# Browse a snapshot
restic ls --repo sftp:nas-restic:/path/to/restic-repo latest

# Restore a single file
restic restore --repo sftp:nas-restic:/path/to/restic-repo latest \
    --target /tmp/restore \
    --include "/Users/you/Documents/important-file.txt"

# Mount all snapshots as a filesystem (read-only)
mkdir /tmp/restic-mount
restic mount --repo sftp:nas-restic:/path/to/restic-repo /tmp/restic-mount
# Browse at /tmp/restic-mount/snapshots/
```

## Optional: Backblaze B2 offsite backup

For offsite protection, you can add a Backblaze B2 backend. The script already supports this — you just need to configure it.

### B2 setup

1. Create a [Backblaze B2](https://www.backblaze.com/b2/cloud-storage.html) account and bucket
2. Create an application key with access to that bucket
3. Initialise the restic repo on B2:

```bash
export B2_ACCOUNT_ID="your-account-id"
export B2_ACCOUNT_KEY="your-application-key"
export RESTIC_PASSWORD="a-different-strong-password"
restic init --repo b2:your-bucket-name
```

4. Store credentials in Keychain:

```bash
security add-generic-password -a restic -s restic-b2-repo -w        # repo password
security add-generic-password -a restic -s restic-b2-account-id -w   # B2 account ID
security add-generic-password -a restic -s restic-b2-account-key -w  # B2 application key
```

5. Update the script config:

```bash
B2_REPO="b2:your-bucket-name"
```

The script will then back up to B2 once daily and prune B2 snapshots with the same retention policy.

## Troubleshooting

**"SKIP: not on AC power"** — The script only runs when plugged in, to avoid draining battery. Plug in and wait for the next hourly run.

**"SKIP: NAS not reachable"** — Your NAS/server isn't responding on the expected host/port. Check you're on your home network and the server is running.

**Exit code 3 warnings** — restic completed the backup but couldn't read some files (macOS TCC restrictions). Grant Full Disk Access to restic (step 9) and review your excludes file to skip TCC-protected directories.

**"repository does not exist"** — Double-check `NAS_REPO` in the script matches the path you used in `restic init`.

## Logs

- **Backup log**: `~/.restic-laptop-backup.log` (script output)
- **launchd log**: `~/.restic-laptop-backup-launchd.log` (stdout/stderr from launchd)

## Disclaimer

This is a personal project shared as-is. It works for me, but I make no guarantees it'll work for you. Back up your backups. Test your restores. If something goes wrong and you lose data, that's on you. 🤷
