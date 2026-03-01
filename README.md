# zfs-backup

> [!NOTE]
> This was created with some AI. Its pretty easy to read the code, but you should know this.


Interactive ZFS backup script for controlled snapshot replication with optional exclusions and dry-run mode.

## Script

`./zfs_backup_interactive.sh`

## Requirements

- `bash`
- `zfs` and `zpool`
- `pv`
- `sudo` access for ZFS operations

## Usage

```bash
./zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_POOL -b BASE_SNAP [-n NEW_SNAP] [-e DATASET]... [-l LOG_FILE] [--dry-run]
```

Options:
- `-s SOURCE_POOL` source pool/dataset root (example: `SOURCE_POOL`)
- `-d DEST_POOL` destination pool/dataset root (example: `DEST_POOL`)
- `-b BASE_SNAP` existing snapshot name to increment from (no `@`)
- `-n NEW_SNAP` new snapshot name to create (default: `YYYYmmdd-HHMMSS`)
- `-e DATASET` child dataset to exclude (repeatable), relative (`EXCLUDED_CHILD`) or full (`SOURCE_POOL/EXCLUDED_CHILD`)
- `-l LOG_FILE` log output path (default: `./zfs-backup-<timestamp>.log`)
- `--dry-run` preview all actions without changing ZFS state
- `-h`, `--help` show help

## Typical Workflow

1. Identify a valid base snapshot (must exist on source and destination roots):

```bash
comm -12 \
  <(zfs list -H -t snapshot -o name -s creation -r SOURCE_POOL | rg '^SOURCE_POOL@' | sed 's/^SOURCE_POOL@//') \
  <(zfs list -H -t snapshot -o name -s creation -r DEST_POOL   | rg '^DEST_POOL@'   | sed 's/^DEST_POOL@//')
```

2. Run a dry-run first:

```bash
./zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_POOL -b BASE_SNAP -n NEW_SNAP -e EXCLUDED_CHILD --log-file=/tmp/backup-dryrun.log --dry-run
```

3. Run live:

```bash
./zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_POOL -b BASE_SNAP -n NEW_SNAP -e EXCLUDED_CHILD --log-file=/tmp/backup-live.log
```

Notes:
- The script is interactive and asks for confirmation before each step.
- If destination pool is already imported, import is skipped automatically.
- Excluded datasets are omitted by removing matching snapshots before send.
- Log output is written to the selected log file and echoed to terminal.

## License

This project is licensed under GNU GPL v3.0 (`GPL-3.0-only`). See `LICENSE`.

## Development Disclaimer

This codebase was produced primarily with AI assistance, with human direction, review, and debugging.
