# Comet Custom Snapshots

This repo contains `comet-snap.sh`, a script for saving/restoring Comet auth/session state (cookies, storage, profile prefs) as reusable snapshots.

## Current machine/runtime alignment

- Current MCP + LaunchAgent Comet runtime uses user data dir:  
  `/Users/lume/Library/Application Support/Comet`
- Current active profile is `Default` (from `Local State` metadata).
- MCP patching targets `${userDataDir}/Default/Preferences` and supports `COMET_USER_DATA_DIR`.

The script is now aligned with that model:

- `COMET_USER_DATA_DIR` controls Comet root (default macOS path above).
- Active profile can be resolved dynamically from `Local State` (with explicit overrides available).
- Snapshots are always stored under `${COMET_ROOT}/custom-snapshots`.

## Profile/path resolution

`comet-snap.sh` resolves target paths in this precedence:

1. `COMET_PROFILE_DIR` (absolute path override)
2. `COMET_PROFILE_NAME` (profile directory name under `COMET_ROOT`)
3. `Local State` inference (tries `profile.last_active_profiles`, then other profile metadata)
4. Fallback: `Default`

`COMET_ROOT` is resolved from:

- `COMET_USER_DATA_DIR` if set
- else default: `~/Library/Application Support/Comet`

Use the built-in `info` command to verify what will be touched:

```bash
bash comet-snap.sh info
```

It prints:

- `COMET_ROOT`
- `COMET_PROFILE`
- `SNAPSHOTS_DIR`
- `PROFILE_EXISTS` (`yes`/`no`)

## Usage (repo-based script)

Run commands from this repo:

```bash
cd /Users/lume/Projects/Perplexity-Comet-Profile-Backup

# Inspect resolved profile/paths
bash comet-snap.sh info

# Save current session
bash comet-snap.sh save <name>

# Restore a snapshot (auto-backs up current state first)
bash comet-snap.sh restore <name>

# List named snapshots
bash comet-snap.sh list

# List auto-backups created before restore
bash comet-snap.sh list-backups

# Delete named snapshot
bash comet-snap.sh delete <name>

# Delete auto-backup
bash comet-snap.sh delete-backup <name>
```

Examples with overrides:

```bash
# Use alternate Comet user data dir
COMET_USER_DATA_DIR="/path/to/Comet" bash comet-snap.sh info

# Force profile by name under COMET_ROOT
COMET_PROFILE_NAME="Profile 2" bash comet-snap.sh save alt-profile

# Force profile by absolute path
COMET_PROFILE_DIR="/path/to/Comet/Default" bash comet-snap.sh list
```

**Comet must be fully closed** before save/restore. The script checks running Comet processes and refuses to proceed if Comet is still running.

## Snapshot contents

Only auth/session-relevant files are included (not cache/history/extensions):

| File / Directory | Contains |
|---|---|
| `Cookies`, `Cookies-journal` | HTTP cookies |
| `Login Data`, `Login Data For Account` | Saved passwords |
| `Local Storage/` | localStorage per origin |
| `IndexedDB/` | IndexedDB per origin |
| `SharedStorage`, `WebStorage/` | Shared/web storage APIs |
| `Web Data`, `Account Web Data` | Autofill/form data |
| `Preferences`, `Secure Preferences` | Profile settings |
| `Sessions/` | Tab/session restore data |

macOS note: cookies/passwords are Keychain-encrypted; snapshots are portable only on the same machine + user account.

## Storage location

Snapshots are written to:

```text
${COMET_ROOT}/custom-snapshots/
  <name>/
    ...
    .meta.json
  .pre-restore-<ts>/
```

Snapshot names: letters, numbers, hyphens, underscores, dots.

## Safety features

- Auto-backup before restore (`.pre-restore-<timestamp>`)
- Atomic save/restore staging
- Metadata-based integrity checks
- Process guard via `pgrep -f "Comet.app/Contents"`
- Stale lock cleanup (`SingletonLock` / `SingletonSocket` / `SingletonCookie`)
