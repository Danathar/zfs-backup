#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Interactive ZFS backup script with optional dry-run mode.
#
# Workflow:
# 1) Show plan and require confirmation.
# 2) Import destination pool without mounting datasets.
# 3) List source/destination snapshots for review.
# 4) Create new recursive source snapshot.
# 5) Optionally destroy snapshots on excluded child datasets.
# 6) Send incremental replication stream with pv progress.
# 7) Verify destination snapshots.
#
# Dry-run behavior:
# - Prints commands that would run.
# - Preserves confirmation prompts.
# - Does not execute any destructive or state-changing commands.
###############################################################################

usage() {
  cat <<'USAGE'
Usage:
  zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_POOL -b BASE_SNAP [-n NEW_SNAP] [-e DATASET]... [-l LOG_FILE] [--dry-run]

Example:
  zfs_backup_interactive.sh \
    -s zfsprod \
    -d backup \
    -b 121825 \
    -n Dec2325 \
    -e youtube

Options:
  -s SOURCE_POOL   Source pool/dataset root (example: zfsprod)
  -d DEST_POOL     Destination pool/dataset root (example: backup)
  -b BASE_SNAP     Existing snapshot name to increment from (no '@')
  -n NEW_SNAP      New snapshot name to create (default: YYYYmmdd-HHMMSS)
  -e DATASET       Child dataset to exclude by deleting BASE/NEW snapshots
                   before send. Repeat flag for multiple datasets.
                   Accepts relative name (youtube) or full path (zfsprod/youtube).
  -l LOG_FILE      Write run output to this file (default: ./zfs-backup-<timestamp>.log)
  --dry-run        Show what would run, but execute nothing
  -h, --help       Show this help
USAGE
}

# Parsed CLI inputs.
RUN_TS="$(date +%Y%m%d-%H%M%S)"
SOURCE=""
DEST=""
BASE_SNAP=""
NEW_SNAP="$RUN_TS"
EXCLUDES=()
DRY_RUN=0
LOG_FILE="./zfs-backup-${RUN_TS}.log"

# Normalize long options so they can appear in any position.
NORMALIZED_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      NORMALIZED_ARGS+=("-x")
      shift
      ;;
    --help)
      NORMALIZED_ARGS+=("-h")
      shift
      ;;
    --log-file)
      if [[ $# -lt 2 ]]; then
        echo "Missing argument for --log-file" >&2
        usage >&2
        exit 1
      fi
      NORMALIZED_ARGS+=("-l" "$2")
      shift 2
      ;;
    --log-file=*)
      LOG_PATH="${1#*=}"
      if [[ -z "$LOG_PATH" ]]; then
        echo "Missing argument for --log-file" >&2
        usage >&2
        exit 1
      fi
      NORMALIZED_ARGS+=("-l" "$LOG_PATH")
      shift
      ;;
    *)
      NORMALIZED_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${NORMALIZED_ARGS[@]}"

while getopts ":s:d:b:n:e:l:hx" opt; do
  case "$opt" in
    s) SOURCE="$OPTARG" ;;
    d) DEST="$OPTARG" ;;
    b) BASE_SNAP="$OPTARG" ;;
    n) NEW_SNAP="$OPTARG" ;;
    e) EXCLUDES+=("$OPTARG") ;;
    l) LOG_FILE="$OPTARG" ;;
    x) DRY_RUN=1 ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Missing argument for -$OPTARG" >&2
      usage >&2
      exit 1
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE" || -z "$DEST" || -z "$BASE_SNAP" ]]; then
  echo "Error: -s, -d, and -b are required." >&2
  usage >&2
  exit 1
fi

if [[ "$BASE_SNAP" == *"@"* || "$NEW_SNAP" == *"@"* ]]; then
  echo "Error: snapshot names must not include '@'." >&2
  exit 1
fi

# Mirror all script output to a per-run log file.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Log file: $LOG_FILE"

###############################################################################
# Prompt helper.
# Any answer other than y/Y is treated as "no".
###############################################################################
confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

###############################################################################
# Command runner helper.
# - Always previews the command.
# - Always asks for approval.
# - Executes only when approved and not in dry-run mode.
###############################################################################
run_step() {
  local title="$1"
  local command="$2"

  echo
  echo "== $title =="
  echo "Will run:"
  echo "  $command"

  if confirm "Proceed?"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] Skipping execution."
    else
      eval "$command"
    fi
  else
    echo "Skipped: $title"
  fi
}

###############################################################################
# Normalize exclude dataset names:
# - "youtube"        -> "zfsprod/youtube" (if SOURCE=zfsprod)
# - "zfsprod/youtube" remains unchanged
###############################################################################
resolve_exclude_dataset() {
  local raw="$1"
  if [[ "$raw" == "$SOURCE" || "$raw" == "$SOURCE/"* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s/%s\n' "$SOURCE" "$raw"
  fi
}

# Tool checks happen early for fast failure.
if ! command -v zpool >/dev/null 2>&1; then
  echo "Error: zpool command not found." >&2
  exit 1
fi
if ! command -v zfs >/dev/null 2>&1; then
  echo "Error: zfs command not found." >&2
  exit 1
fi
if ! command -v pv >/dev/null 2>&1; then
  echo "Error: pv is required for progress display but was not found." >&2
  exit 1
fi

# Incremental send command with progress meter.
SEND_PIPE_CMD="sudo zfs send -R -I ${SOURCE}@${BASE_SNAP} ${SOURCE}@${NEW_SNAP} --skip-missing | pv -f -pterab | sudo zfs recv -F ${DEST}"

echo "Planned backup:"
echo "  Source:          $SOURCE"
echo "  Destination:     $DEST"
echo "  Base snapshot:   ${SOURCE}@${BASE_SNAP}"
echo "  New snapshot:    ${SOURCE}@${NEW_SNAP}"
echo "  Import step:     sudo zpool import -N ${DEST}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  Mode:            DRY-RUN (no commands executed)"
else
  echo "  Mode:            LIVE"
fi

if ((${#EXCLUDES[@]} > 0)); then
  echo "  Excluded dataset snapshots:"
  for x in "${EXCLUDES[@]}"; do
    echo "    - $(resolve_exclude_dataset "$x")"
  done
else
  echo "  Excluded dataset snapshots: none"
fi

if ! confirm "Continue with this plan?"; then
  echo "Aborted."
  exit 0
fi

if zpool list -H -o name "$DEST" >/dev/null 2>&1; then
  echo
  echo "== Import destination pool without mounting =="
  echo "Destination pool '${DEST}' is already imported. Skipping import step."
  if zfs list -H -o mounted -r "$DEST" 2>/dev/null | grep -q '^yes$'; then
    echo "Note: one or more datasets under '${DEST}' are currently mounted."
  else
    echo "Datasets under '${DEST}' are not mounted."
  fi
else
  run_step "Import destination pool without mounting" "sudo zpool import -N ${DEST}"
fi
run_step "List source snapshots" "zfs list -t snapshot -r ${SOURCE}"
run_step "List destination snapshots" "zfs list -t snapshot -r ${DEST}"
run_step "Create recursive snapshot ${SOURCE}@${NEW_SNAP}" "sudo zfs snapshot -r ${SOURCE}@${NEW_SNAP}"

###############################################################################
# Exclusion cleanup:
# For each excluded dataset, remove BASE and NEW snapshots so that child dataset
# is excluded from replicated stream when using the recursive send pattern.
#
# In dry-run mode:
# - We cannot rely on live snapshot existence checks because nothing changes.
# - So we print both destroy commands directly for review.
###############################################################################
if ((${#EXCLUDES[@]} > 0)); then
  DESTROY_CMDS=()
  for raw in "${EXCLUDES[@]}"; do
    ds="$(resolve_exclude_dataset "$raw")"
    for snap in "$BASE_SNAP" "$NEW_SNAP"; do
      snap_path="${ds}@${snap}"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        DESTROY_CMDS+=("sudo zfs destroy ${snap_path}")
      else
        if zfs list -H -o name -t snapshot "$snap_path" >/dev/null 2>&1; then
          DESTROY_CMDS+=("sudo zfs destroy ${snap_path}")
        else
          echo "Note: snapshot not present, nothing to destroy: ${snap_path}"
        fi
      fi
    done
  done

  if ((${#DESTROY_CMDS[@]} > 0)); then
    echo
    echo "== Exclusion snapshot cleanup =="
    echo "Will run:"
    for cmd in "${DESTROY_CMDS[@]}"; do
      echo "  $cmd"
    done
    if confirm "Proceed with destroy commands?"; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] Skipping execution."
      else
        for cmd in "${DESTROY_CMDS[@]}"; do
          eval "$cmd"
        done
      fi
    else
      echo "Skipped exclusion snapshot cleanup."
    fi
  fi
fi

run_step "Send incremental stream to ${DEST}" "$SEND_PIPE_CMD"
run_step "Verify destination snapshots" "zfs list -t snapshot -r ${DEST}"

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run complete. No ZFS state was changed."
else
  echo "Backup workflow finished."
fi
