# zfs-backup

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
- `-s SOURCE_POOL` source pool/dataset root (example: `zfsprod`)
- `-d DEST_POOL` destination pool/dataset root (example: `backup`)
- `-b BASE_SNAP` existing snapshot name to increment from (no `@`)
- `-n NEW_SNAP` new snapshot name to create (default: `YYYYmmdd-HHMMSS`)
- `-e DATASET` child dataset to exclude (repeatable), relative (`youtube`) or full (`zfsprod/youtube`)
- `-l LOG_FILE` log output path (default: `./zfs-backup-<timestamp>.log`)
- `--dry-run` preview all actions without changing ZFS state
- `-h`, `--help` show help

## Typical Workflow

1. Identify a valid base snapshot (must exist on source and destination roots):

```bash
comm -12 \
  <(zfs list -H -t snapshot -o name -s creation -r zfsprod | rg '^zfsprod@' | sed 's/^zfsprod@//') \
  <(zfs list -H -t snapshot -o name -s creation -r backup  | rg '^backup@'  | sed 's/^backup@//')
```

2. Run a dry-run first:

```bash
./zfs_backup_interactive.sh -s zfsprod -d backup -b Dec3025 -n Feb1126 -e youtube --log-file=/tmp/backup-dryrun.log --dry-run
```

3. Run live:

```bash
./zfs_backup_interactive.sh -s zfsprod -d backup -b Dec3025 -n Feb1126 -e youtube --log-file=/tmp/backup-live.log
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
