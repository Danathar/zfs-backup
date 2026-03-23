# zfs-backup

> [!NOTE]
> This was created with some AI. Its pretty easy to read the code, but you should know this.


Interactive incremental ZFS backup script for controlled snapshot replication with optional exclusions and dry-run mode.

## Script

`./zfs_backup_interactive.sh`

## Requirements

- `bash`
- `zfs` and `zpool`
- `pv`
- `sudo` access for ZFS operations
- OpenZFS with native `zfs send -X` exclusion support

## Usage

```bash
./zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_ROOT -b BASE_SNAP [-n NEW_SNAP] [-e DATASET]... [-l LOG_FILE] [--dry-run]
```

Options:
- `-s SOURCE_POOL` source pool/dataset root (example: `SOURCE_POOL`)
- `-d DEST_ROOT` destination pool or dataset root (example: `DEST_POOL` or `DEST_POOL/BACKUPS`)
- `-b BASE_SNAP` existing snapshot name to increment from (no `@`)
- `-n NEW_SNAP` new snapshot name to create (default: `YYYYmmdd-HHMMSS`)
- `-e DATASET` child dataset to exclude (repeatable), relative (`EXCLUDED_CHILD`) or full (`SOURCE_POOL/EXCLUDED_CHILD`)
- `-l LOG_FILE` log output path (default: `./zfs-backup-<timestamp>.log`)
- `--dry-run` preview all actions without changing ZFS state
- `-h`, `--help` show help

Notes:
- This script is for incremental replication. The destination must already contain the base snapshot on the destination root.
- The destination target must not have mounted datasets underneath the selected destination root.
- A dry-run only validates the destination if the destination pool is already imported. If you want destination-side validation during a dry-run, import the pool first with `sudo zpool import -N DEST_POOL`.

## Typical Workflow

1. Identify a valid base snapshot. It must exist on both the source root and the destination root:

```bash
comm -12 \
  <(sudo zfs list -H -t snapshot -o name -s creation -r SOURCE_POOL | rg '^SOURCE_POOL@' | sed 's/^SOURCE_POOL@//') \
  <(sudo zfs list -H -t snapshot -o name -s creation -r DEST_ROOT   | rg '^DEST_ROOT@'   | sed 's/^DEST_ROOT@//')
```

2. If the destination pool is not already imported and you want the dry-run to validate destination state, import it without mounting:

```bash
sudo zpool import -N DEST_POOL
```

3. Run a dry-run first:

```bash
./zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_ROOT -b BASE_SNAP -n NEW_SNAP -e EXCLUDED_CHILD --log-file=/tmp/backup-dryrun.log --dry-run
```

4. Run live:

```bash
./zfs_backup_interactive.sh -s SOURCE_POOL -d DEST_ROOT -b BASE_SNAP -n NEW_SNAP -e EXCLUDED_CHILD --log-file=/tmp/backup-live.log
```

Notes:
- The script is interactive and asks for confirmation before each step.
- If the destination pool is already imported, the import step is skipped automatically.
- The script validates the destination root and every non-excluded descendant dataset for the selected base snapshot before it creates the new source snapshot.
- Excluded datasets are omitted with native `zfs send -R -X ...`; the script no longer deletes source snapshots to implement exclusions.
- The receive side uses `zfs recv -u -F -x mountpoint` so the backup does not mount datasets during receive and does not inherit source mountpoints onto the backup host.
- In live mode, the script calculates the exact stream size first and passes it to `pv` so progress percentage and ETA are meaningful.
- Log output is written to the selected log file and echoed to terminal.

## License

This project is licensed under GNU GPL v3.0 (`GPL-3.0-only`). See `LICENSE`.

## Development Disclaimer

This codebase was produced primarily with AI assistance, with human direction, review, and debugging.
