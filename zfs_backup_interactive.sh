#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Interactive incremental ZFS backup script with optional dry-run mode.
#
# Workflow:
# 1) Show plan and require confirmation.
# 2) Import destination pool without mounting datasets.
# 3) List source/destination snapshots for review.
# 4) Build a native exclusion list for zfs send.
# 5) Validate the destination/base snapshot tree before mutating source state.
# 6) List source/destination snapshots for review.
# 7) Create a new recursive source snapshot.
# 8) Calculate exact stream size for pv when running live.
# 9) Send incremental replication stream with pv progress.
# 10) Verify destination snapshots.
#
# Dry-run behavior:
# - Prints commands that would run.
# - Preserves confirmation prompts.
# - Does not execute any destructive or state-changing commands.
#
# Development disclaimer:
# - This script was produced primarily with AI assistance, with human input,
#   review, and debugging.
###############################################################################

usage() {
  cat <<'USAGE'
Usage:
  zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_ROOT -b BASE_SNAP [-n NEW_SNAP] [-e DATASET]... [-l LOG_FILE] [--dry-run]

Example:
  zfs_backup_interactive.sh \
    -s SOURCE_POOL \
    -d DEST_ROOT \
    -b BASE_SNAP \
    -n NEW_SNAP \
    -e EXCLUDED_CHILD

Options:
  -s SOURCE_POOL   Source pool/dataset root (example: SOURCE_POOL)
  -d DEST_ROOT     Destination pool or dataset root (example: DEST_POOL or DEST_POOL/BACKUPS)
  -b BASE_SNAP     Existing snapshot name to increment from (no '@')
  -n NEW_SNAP      New snapshot name to create (default: YYYYmmdd-HHMMSS)
  -e DATASET       Child dataset to exclude from the replication stream.
                   Repeat flag for multiple datasets. Accepts relative
                   name (EXCLUDED_CHILD) or full path
                   (SOURCE_POOL/EXCLUDED_CHILD).
  -l LOG_FILE      Write run output to this file (default: ./zfs-backup-<timestamp>.log)
  --dry-run        Show what would run, but execute nothing
  -h, --help       Show this help
USAGE
}

# Parsed CLI inputs.
RUN_TS="$(date +%Y%m%d-%H%M%S)"
SOURCE=""
DEST=""
DEST_POOL=""
BASE_SNAP=""
NEW_SNAP="$RUN_TS"
EXCLUDES=()
NORMALIZED_EXCLUDES=()
DRY_RUN=0
LOG_FILE="./zfs-backup-${RUN_TS}.log"
SEND_SIZE=""
SEND_CMD=()
PV_CMD=()
RECV_CMD=()

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

DEST_POOL="${DEST%%/*}"

# Mirror all script output to a per-run log file.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Log file: $LOG_FILE"

die() {
  echo "Error: $*" >&2
  exit 1
}

quote_cmd() {
  local rendered
  printf -v rendered '%q ' "$@"
  printf '%s' "${rendered% }"
}

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
  shift

  echo
  echo "== $title =="
  echo "Will run:"
  echo "  $(quote_cmd "$@")"

  if confirm "Proceed?"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] Skipping execution."
    else
      "$@"
    fi
  else
    echo "Skipped: $title"
  fi
}

run_pipeline_step() {
  local title="$1"

  echo
  echo "== $title =="
  echo "Will run:"
  echo "  $(quote_cmd "${SEND_CMD[@]}") | $(quote_cmd "${PV_CMD[@]}") | $(quote_cmd "${RECV_CMD[@]}")"

  if confirm "Proceed?"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] Skipping execution."
    else
      "${SEND_CMD[@]}" | "${PV_CMD[@]}" | "${RECV_CMD[@]}"
    fi
  else
    echo "Skipped: $title"
  fi
}

###############################################################################
# Normalize exclude dataset names:
# - "EXCLUDED_CHILD"              -> "SOURCE_POOL/EXCLUDED_CHILD"
# - "SOURCE_POOL/EXCLUDED_CHILD" remains unchanged
###############################################################################
resolve_exclude_dataset() {
  local raw="$1"
  if [[ "$raw" == "$SOURCE" || "$raw" == "$SOURCE/"* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s/%s\n' "$SOURCE" "$raw"
  fi
}

dataset_exists() {
  sudo zfs list -H -o name "$1" >/dev/null 2>&1
}

snapshot_exists() {
  sudo zfs list -H -o name -t snapshot "$1" >/dev/null 2>&1
}

require_dataset_exists() {
  local dataset="$1"
  local label="$2"
  if ! dataset_exists "$dataset"; then
    die "${label} not found: ${dataset}"
  fi
}

require_snapshot_exists() {
  local snapshot="$1"
  local label="$2"
  if ! snapshot_exists "$snapshot"; then
    die "${label} not found: ${snapshot}"
  fi
}

human_size() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    printf '%s bytes\n' "$bytes"
  fi
}

dataset_is_excluded() {
  local dataset="$1"
  local excluded

  for excluded in "${NORMALIZED_EXCLUDES[@]}"; do
    if [[ "$dataset" == "$excluded" || "$dataset" == "$excluded/"* ]]; then
      return 0
    fi
  done

  return 1
}

map_source_dataset_to_dest() {
  local source_dataset="$1"
  if [[ "$source_dataset" == "$SOURCE" ]]; then
    printf '%s\n' "$DEST"
  else
    printf '%s%s\n' "$DEST" "${source_dataset#"$SOURCE"}"
  fi
}

validate_destination_base_tree() {
  local source_dataset
  local dest_dataset

  while IFS= read -r source_dataset; do
    if dataset_is_excluded "$source_dataset"; then
      continue
    fi

    dest_dataset="$(map_source_dataset_to_dest "$source_dataset")"
    require_dataset_exists "$dest_dataset" "destination dataset"
    require_snapshot_exists "${dest_dataset}@${BASE_SNAP}" "destination base snapshot"
  done < <(sudo zfs list -H -o name -t filesystem,volume -r "$SOURCE")
}

build_send_cmd() {
  SEND_CMD=(sudo zfs send -R)
  for ds in "${NORMALIZED_EXCLUDES[@]}"; do
    SEND_CMD+=(-X "$ds")
  done
  SEND_CMD+=(-I "${SOURCE}@${BASE_SNAP}" "${SOURCE}@${NEW_SNAP}")
}

build_pv_cmd() {
  PV_CMD=(pv -f -pterab)
  if [[ -n "$SEND_SIZE" ]]; then
    PV_CMD+=(-s "$SEND_SIZE")
  fi
}

build_recv_cmd() {
  RECV_CMD=(sudo zfs recv -u -F -x mountpoint "$DEST")
}

calculate_send_size() {
  local output
  local size
  local -a size_cmd=(sudo zfs send -nP -R)

  for ds in "${NORMALIZED_EXCLUDES[@]}"; do
    size_cmd+=(-X "$ds")
  done
  size_cmd+=(-I "${SOURCE}@${BASE_SNAP}" "${SOURCE}@${NEW_SNAP}")

  if ! output="$("${size_cmd[@]}" 2>&1)"; then
    echo "$output"
    return 1
  fi

  size="$(awk -F '\t' '/^(full|incremental)\t/ {sum += $NF} END {print sum+0}' <<<"$output")"
  if [[ "$size" -le 0 ]]; then
    echo "$output"
    return 1
  fi

  printf '%s\n' "$size"
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

require_dataset_exists "$SOURCE" "source dataset"
require_snapshot_exists "${SOURCE}@${BASE_SNAP}" "source base snapshot"

if ((${#EXCLUDES[@]} > 0)); then
  for raw in "${EXCLUDES[@]}"; do
    ds="$(resolve_exclude_dataset "$raw")"
    if [[ "$ds" == "$SOURCE" ]]; then
      die "refusing to exclude the root dataset: ${ds}"
    fi
    require_dataset_exists "$ds" "excluded dataset"
    NORMALIZED_EXCLUDES+=("$ds")
  done
fi

echo "Planned backup:"
echo "  Source:          $SOURCE"
echo "  Destination:     $DEST"
echo "  Base snapshot:   ${SOURCE}@${BASE_SNAP}"
echo "  New snapshot:    ${SOURCE}@${NEW_SNAP}"
echo "  Destination pool: ${DEST_POOL}"
echo "  Import step:      sudo zpool import -N ${DEST_POOL}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  Mode:            DRY-RUN (no commands executed)"
else
  echo "  Mode:            LIVE"
fi

if ((${#NORMALIZED_EXCLUDES[@]} > 0)); then
  echo "  Excluded datasets:"
  for x in "${NORMALIZED_EXCLUDES[@]}"; do
    echo "    - $x"
  done
else
  echo "  Excluded datasets: none"
fi

if ! confirm "Continue with this plan?"; then
  echo "Aborted."
  exit 0
fi

DEST_IMPORTED=0
if sudo zpool list -H -o name "$DEST_POOL" >/dev/null 2>&1; then
  DEST_IMPORTED=1
  echo
  echo "== Import destination pool without mounting =="
  echo "Destination pool '${DEST_POOL}' is already imported. Skipping import step."
else
  run_step "Import destination pool without mounting" sudo zpool import -N "$DEST_POOL"
  if sudo zpool list -H -o name "$DEST_POOL" >/dev/null 2>&1; then
    DEST_IMPORTED=1
  fi
fi

if [[ "$DEST_IMPORTED" -eq 1 ]]; then
  validate_destination_base_tree
  if sudo zfs list -H -o mounted -r "$DEST" 2>/dev/null | grep -q '^yes$'; then
    die "one or more datasets under '${DEST}' are mounted; unmount/export the destination before running this script"
  fi
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "Note: destination validation skipped in dry-run mode because '${DEST_POOL}' is not imported."
  else
    die "destination pool '${DEST_POOL}' is not imported"
  fi
fi

run_step "List source snapshots" sudo zfs list -t snapshot -r "$SOURCE"
run_step "List destination snapshots" sudo zfs list -t snapshot -r "$DEST"
run_step "Create recursive snapshot ${SOURCE}@${NEW_SNAP}" sudo zfs snapshot -r "${SOURCE}@${NEW_SNAP}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Note: exact send size is not calculated in dry-run mode because ${SOURCE}@${NEW_SNAP} is not created."
else
  echo
  echo "== Calculate exact send size =="
  if ! SEND_SIZE="$(calculate_send_size)"; then
    die "failed to calculate send size for ${SOURCE}@${NEW_SNAP}"
  fi
  echo "Stream size: ${SEND_SIZE} bytes ($(human_size "$SEND_SIZE"))"
fi

build_send_cmd
build_pv_cmd
build_recv_cmd

run_pipeline_step "Send incremental stream to ${DEST}"
run_step "Verify destination snapshots" sudo zfs list -t snapshot -r "$DEST"

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run complete. No ZFS state was changed."
else
  echo "Backup workflow finished."
fi
