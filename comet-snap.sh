#!/usr/bin/env bash
# comet-snap — Snapshot and restore Comet browser session data
#
# Usage:
#   comet-snap save <name>          Save current session to a named snapshot
#   comet-snap restore <name>       Restore a snapshot (auto-backs up current state first)
#   comet-snap list                 List all named snapshots
#   comet-snap list-backups         List auto-backups created before each restore
#   comet-snap delete <name>        Delete a named snapshot
#   comet-snap delete-backup <name> Delete an auto-backup
#
# Comet must be fully closed before save or restore.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

COMET_ROOT="$HOME/Library/Application Support/Comet"
COMET_PROFILE="$COMET_ROOT/Default"
SNAPSHOTS_DIR="$COMET_ROOT/custom-snapshots"
MAX_AUTO_BACKUPS=5

SNAPSHOT_TARGETS=(
  "Cookies"
  "Cookies-journal"
  "Login Data"
  "Login Data-journal"
  "Login Data For Account"
  "Login Data For Account-journal"
  "Local Storage"
  "IndexedDB"
  "SharedStorage"
  "WebStorage"
  "Web Data"
  "Web Data-journal"
  "Account Web Data"
  "Account Web Data-journal"
  "Preferences"
  "Secure Preferences"
  "Sessions"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err()  { echo "❌  $*" >&2; exit 1; }
info() { echo "ℹ️   $*"; }
ok()   { echo "✅  $*"; }
warn() { echo "⚠️   $*"; }

preflight() {
  command -v python3 >/dev/null 2>&1 || err "python3 is required but not found. Install Xcode Command Line Tools: xcode-select --install"
}

validate_name() {
  local name="$1"
  [[ -n "$name" ]]                        || err "Snapshot name cannot be empty."
  [[ "$name" != "." && "$name" != ".." ]] || err "Invalid snapshot name: '$name'"
  [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]]     || err "Invalid snapshot name '$name'. Use only letters, numbers, hyphens, underscores, dots."
  [[ "$name" != *.meta.json ]]            || err "Invalid snapshot name: '$name'"
  # Block dot-prefixed names from user-facing commands — those are internal auto-backups
  [[ "$name" != .* ]]                     || err "Names starting with '.' are reserved for auto-backups. Use 'list-backups' / 'delete-backup' to manage them."
}

validate_backup_name() {
  local name="$1"
  [[ -n "$name" ]]                        || err "Backup name cannot be empty."
  [[ "$name" =~ ^\.pre-restore-[0-9]{8}-[0-9]{6}$ ]] \
    || err "Invalid backup name '$name'. Use 'list-backups' to see valid names."
}

check_comet_closed() {
  if pgrep -f "Comet.app/Contents" > /dev/null 2>&1; then
    err "Comet is still running. Quit Comet fully before running comet-snap."
  fi
  # Clean up stale singleton lock files left behind by crashes
  for f in "$COMET_ROOT"/Singleton{Lock,Socket,Cookie}; do
    if [[ -e "$f" || -L "$f" ]]; then
      rm -f "$f"
      info "Removed stale lock file: $(basename "$f")"
    fi
  done
}

# Copy SNAPSHOT_TARGETS from $1 (source dir) into $2 (destination dir).
# Prints the number of files copied to stdout. Uses cp -RP to preserve symlinks.
copy_targets() {
  local src="$1"
  local dst="$2"
  local saved=0
  mkdir -p "$dst"
  for target in "${SNAPSHOT_TARGETS[@]}"; do
    local s="$src/$target"
    if [[ -e "$s" ]]; then
      cp -RP "$s" "$dst/"
      (( ++saved ))
    fi
  done
  echo "$saved"
}

write_meta() {
  local dir="$1" name="$2" count="$3"
  python3 -c "
import json, sys
from datetime import datetime
data = {'name': sys.argv[1], 'created': datetime.now().isoformat(), 'items': int(sys.argv[2])}
print(json.dumps(data, indent=2))
" "$name" "$count" > "$dir/.meta.json"
}

read_meta() {
  local dir="$1" field="$2"
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        data = json.load(f)
    print(data.get(sys.argv[2], ''))
except Exception:
    print('')
" "$dir/.meta.json" "$field" 2>/dev/null || echo ""
}

verify_snapshot_integrity() {
  local snap_dir="$1" name="$2"
  [[ -d "$snap_dir" ]]            || err "Snapshot '$name' not found."
  [[ -f "$snap_dir/.meta.json" ]] || err "Snapshot '$name' is incomplete (missing metadata). It may have been interrupted during save — delete it and re-save."
  local expected
  expected=$(read_meta "$snap_dir" "items")
  if [[ -n "$expected" && "$expected" -gt 0 ]]; then
    local actual=0
    for target in "${SNAPSHOT_TARGETS[@]}"; do
      [[ -e "$snap_dir/$target" ]] && (( ++actual ))
    done
    if [[ "$actual" -lt "$expected" ]]; then
      err "Snapshot '$name' is incomplete ($actual/$expected files). It may have been interrupted — delete and re-save."
    fi
  fi
}

prompt_confirm() {
  local msg="$1" answer
  echo -n "   $msg [y/N] "
  read -r -t 60 answer || { echo ""; info "Timed out. Aborted."; exit 0; }
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { info "Aborted."; exit 0; }
}

# Remove oldest auto-backups, keeping only the most recent $MAX_AUTO_BACKUPS
prune_old_backups() {
  local dirs=()
  for d in "$SNAPSHOTS_DIR"/.pre-restore-*/; do
    [[ -d "$d" ]] && dirs+=("$d")
  done
  local count=${#dirs[@]}
  if [[ $count -gt $MAX_AUTO_BACKUPS ]]; then
    # Sort by name (timestamp-based names sort lexicographically = chronologically)
    IFS=$'\n' sorted=($(printf '%s\n' "${dirs[@]}" | sort))
    unset IFS
    local to_delete=$(( count - MAX_AUTO_BACKUPS ))
    for (( i=0; i<to_delete; i++ )); do
      rm -rf "${sorted[$i]}"
      info "Pruned old auto-backup: $(basename "${sorted[$i]}")"
    done
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_save() {
  local name="${1:-}"
  [[ -n "$name" ]] || { usage; exit 1; }
  validate_name "$name"
  [[ $# -le 1 ]] || err "Too many arguments. Usage: comet-snap save <name>"
  check_comet_closed

  local dest="$SNAPSHOTS_DIR/$name"
  local tmp_dir
  tmp_dir=$(mktemp -d "$SNAPSHOTS_DIR/.save-tmp-XXXXXX")
  trap 'rm -rf "$tmp_dir"' EXIT

  if [[ -d "$dest" ]]; then
    warn "Snapshot '$name' already exists."
    prompt_confirm "Overwrite it?"
  fi

  info "Saving snapshot '$name'..."
  local count
  count=$(copy_targets "$COMET_PROFILE" "$tmp_dir")
  write_meta "$tmp_dir" "$name" "$count"

  # Atomically replace: only remove old snapshot after staging succeeds
  rm -rf "$dest"
  mv "$tmp_dir" "$dest"

  trap - EXIT
  ok "Saved '$name' ($count files copied)."
}

cmd_restore() {
  local name="${1:-}"
  [[ -n "$name" ]] || { usage; exit 1; }
  [[ $# -le 1 ]] || err "Too many arguments. Usage: comet-snap restore <name>"

  # Allow both named snapshots and auto-backups to be restored
  local snap_dir
  if [[ "$name" == .pre-restore-* ]]; then
    validate_backup_name "$name"
    snap_dir="$SNAPSHOTS_DIR/$name"
    [[ -d "$snap_dir" ]] || err "Auto-backup '$name' not found. Use 'list-backups' to see available backups."
  else
    validate_name "$name"
    snap_dir="$SNAPSHOTS_DIR/$name"
    verify_snapshot_integrity "$snap_dir" "$name"
  fi

  check_comet_closed

  warn "This will overwrite your current Comet session data."
  warn "Cookies (Keychain-encrypted): only portable on this machine/user."
  warn "If your macOS Keychain was reset since this snapshot was taken, cookies will silently fail."
  prompt_confirm "Restore '$name'?"

  # Auto-backup current state before touching anything
  local backup_name=".pre-restore-$(date +%Y%m%d-%H%M%S)"
  local backup_dir="$SNAPSHOTS_DIR/$backup_name"
  if [[ -d "$COMET_PROFILE" ]]; then
    info "Auto-backing up current session to '$backup_name'..."
    local backup_count
    backup_count=$(copy_targets "$COMET_PROFILE" "$backup_dir")
    write_meta "$backup_dir" "$backup_name" "$backup_count"
    info "Backup saved ($backup_count files)."
    prune_old_backups
  fi

  # Stage restore to a temp dir first, then atomically move into place
  local tmp_dir
  tmp_dir=$(mktemp -d "$SNAPSHOTS_DIR/.restore-tmp-XXXXXX")
  trap 'rm -rf "$tmp_dir"' EXIT

  info "Staging restore..."
  local staged=0
  for target in "${SNAPSHOT_TARGETS[@]}"; do
    local s="$snap_dir/$target"
    if [[ -e "$s" ]]; then
      cp -RP "$s" "$tmp_dir/"
      (( ++staged ))
    fi
  done

  # Atomically replace — remove old targets, move staged ones in
  mkdir -p "$COMET_PROFILE"
  for target in "${SNAPSHOT_TARGETS[@]}"; do
    local staged_file="$tmp_dir/$target"
    if [[ -e "$staged_file" ]]; then
      rm -rf "$COMET_PROFILE/$target"
      mv "$staged_file" "$COMET_PROFILE/"
    fi
  done

  trap - EXIT
  rm -rf "$tmp_dir"

  ok "Restored '$name' ($staged files). Launch Comet to apply."
  if [[ "$name" != .pre-restore-* ]]; then
    info "Previous session backed up as '$backup_name' (use 'comet-snap restore $backup_name' to undo)."
  fi
}

cmd_list() {
  local found=0
  echo ""
  for snap_dir in "$SNAPSHOTS_DIR"/*/; do
    [[ -d "$snap_dir" ]] || continue
    local bname
    bname=$(basename "$snap_dir")
    [[ "$bname" == .* ]] && continue  # skip internal dot-dirs
    local created items
    created=$(read_meta "$snap_dir" "created")
    items=$(read_meta "$snap_dir" "items")
    printf "  %-30s  %s  (%s files)\n" "$bname" "${created:-(no metadata)}" "${items:-?}"
    (( ++found ))
  done

  if [[ $found -eq 0 ]]; then
    info "No snapshots yet. Run: comet-snap save <name>"
  else
    echo ""
    echo "  $found snapshot(s)."
  fi

  local backups=0
  for snap_dir in "$SNAPSHOTS_DIR"/.pre-restore-*/; do
    [[ -d "$snap_dir" ]] && (( ++backups ))
  done
  if [[ $backups -gt 0 ]]; then
    echo "  $backups auto-backup(s) stored (max $MAX_AUTO_BACKUPS kept). Use 'comet-snap list-backups' to view."
  fi
  echo ""
}

cmd_list_backups() {
  local found=0
  echo ""
  for snap_dir in "$SNAPSHOTS_DIR"/.pre-restore-*/; do
    [[ -d "$snap_dir" ]] || continue
    local bname created items
    bname=$(basename "$snap_dir")
    created=$(read_meta "$snap_dir" "created")
    items=$(read_meta "$snap_dir" "items")
    printf "  %-45s  %s  (%s files)\n" "$bname" "${created:-(no metadata)}" "${items:-?}"
    (( ++found ))
  done
  if [[ $found -eq 0 ]]; then
    info "No auto-backups found."
  else
    echo ""
    echo "  $found auto-backup(s). To restore: comet-snap restore <name>"
    echo "  To delete: comet-snap delete-backup <name>"
  fi
  echo ""
}

cmd_delete() {
  local name="${1:-}"
  [[ -n "$name" ]] || { usage; exit 1; }
  [[ $# -le 1 ]] || err "Too many arguments. Usage: comet-snap delete <name>"
  validate_name "$name"  # blocks dot-prefixed names
  local target="$SNAPSHOTS_DIR/$name"
  [[ -d "$target" ]] || err "Snapshot '$name' not found."
  prompt_confirm "Delete snapshot '$name'? This cannot be undone."
  rm -rf "$target"
  ok "Deleted '$name'."
}

cmd_delete_backup() {
  local name="${1:-}"
  [[ -n "$name" ]] || { usage; exit 1; }
  [[ $# -le 1 ]] || err "Too many arguments. Usage: comet-snap delete-backup <name>"
  validate_backup_name "$name"
  local target="$SNAPSHOTS_DIR/$name"
  [[ -d "$target" ]] || err "Auto-backup '$name' not found. Use 'list-backups' to see available backups."
  prompt_confirm "Delete auto-backup '$name'? This cannot be undone."
  rm -rf "$target"
  ok "Deleted '$name'."
}

usage() {
  cat <<EOF

Usage:
  comet-snap save <name>           Save current Comet session to a named snapshot
  comet-snap restore <name>        Restore a snapshot (auto-backs up current state first)
  comet-snap list                  List all named snapshots
  comet-snap list-backups          List auto-backups created before each restore
  comet-snap delete <name>         Delete a named snapshot
  comet-snap delete-backup <name>  Delete an auto-backup

Notes:
  - Comet must be fully closed before save or restore
  - Snapshots stored in: $SNAPSHOTS_DIR
  - Cookies are Keychain-encrypted — snapshots only work on this machine/user
  - Names: letters, numbers, hyphens, underscores, dots only
  - Auto-backups are kept automatically (last $MAX_AUTO_BACKUPS retained)

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

preflight

CMD="${1:-}"
shift || true

case "$CMD" in
  save)           cmd_save "$@" ;;
  restore)        cmd_restore "$@" ;;
  list)           cmd_list ;;
  list-backups)   cmd_list_backups ;;
  delete)         cmd_delete "$@" ;;
  delete-backup)  cmd_delete_backup "$@" ;;
  *)              usage; exit 1 ;;
esac
