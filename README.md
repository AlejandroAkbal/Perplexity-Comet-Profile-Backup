# Comet Custom Snapshots

This directory contains snapshots of the Comet browser's session data — specifically cookies, local storage, and other auth-related files. The goal is to preserve a "logged-in" state so it can be restored at any time, without keeping sensitive data in the live profile permanently.

## Why this exists

Comet doesn't support private/incognito profiles in a way that's controllable via MCP. Instead of using the live profile (which accumulates data), we snapshot just the essential session files, wipe the profile when needed, and restore from a snapshot when we want a known state back.

## What gets snapshotted

Only auth and session-relevant files — not cache, history, extensions, or anything else:

| File / Directory | Contains |
|---|---|
| `Cookies`, `Cookies-journal` | HTTP cookies (all sites) |
| `Login Data`, `Login Data For Account` | Saved passwords |
| `Local Storage/` | localStorage per origin |
| `IndexedDB/` | IndexedDB per origin |
| `SharedStorage`, `WebStorage/` | Shared/web storage APIs |
| `Web Data`, `Account Web Data` | Autofill, form data |
| `Preferences`, `Secure Preferences` | Profile settings |
| `Sessions/` | Tab/session restore data |

**Note:** On macOS, cookies and passwords are encrypted using a key stored in the system Keychain under Comet's bundle ID. Snapshots are only portable on the **same machine and user account**. If your macOS Keychain is reset (e.g. after an OS reinstall), restored cookies will be silently dropped — Comet will just show you as logged out.

## Usage

```bash
# Save current session
bash comet-snap.sh save <name>

# Restore a snapshot (auto-backs up current state first)
bash comet-snap.sh restore <name>

# List all snapshots
bash comet-snap.sh list

# List auto-backups created before each restore
bash comet-snap.sh list-backups

# Delete a snapshot
bash comet-snap.sh delete <name>
```

**Comet must be fully closed** before saving or restoring — otherwise SQLite and LevelDB files will be locked. The script checks for all Comet processes (including GPU and renderer helpers) and will refuse to run if any are still alive.

## Snapshot storage

Each snapshot is stored as a subdirectory here:

```text
custom-snapshots/
  <name>/
    Cookies
    Local Storage/
    ...
    .meta.json          ← name, timestamp, and item count (integrity check)
  .pre-restore-<ts>/    ← auto-backups created before each restore (hidden)
```

Snapshot names may only contain letters, numbers, hyphens, underscores, and dots.

## Safety features

- **Auto-backup before restore**: every `restore` command automatically snapshots your current session as `.pre-restore-<timestamp>` before touching anything. Use `comet-snap.sh list-backups` to see them and `restore .pre-restore-<name>` to undo a restore.
- **Atomic restore**: files are staged to a temp directory first, then moved into the profile atomically. A failed restore never leaves the profile in a broken half-state.
- **Integrity check**: each snapshot records how many files were copied. An interrupted save is detected and rejected at restore time.
- **Process check**: uses `pgrep -f "Comet.app/Contents"` to detect all Comet subprocesses, not just the main window.
- **Stale lock cleanup**: removes leftover `SingletonLock`/`SingletonSocket`/`SingletonCookie` files from crash sessions before proceeding.

## Typical workflow

1. Log in to all your sites in Comet normally
2. Close Comet fully
3. `bash comet-snap.sh save logged-in`
4. Use Comet — browse freely, accumulate junk data
5. When you want a clean slate: close Comet, wipe only the `Default/` profile dir, restore:
   ```bash
   rm -rf ~/Library/Application\ Support/Comet/Default
   bash ~/Library/Application\ Support/Comet/custom-snapshots/comet-snap.sh restore logged-in
   ```
6. Reopen Comet — fully logged in, clean profile

> ⚠️ Only delete `Default/` — never delete the entire `Comet/` directory, as that would also remove this script and all your snapshots.
