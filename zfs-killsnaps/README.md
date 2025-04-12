# ZFS Snapshot Cleanup Tool

A powerful and flexible utility for managing ZFS snapshots.

This script is designed to automate the deletion of ZFS snapshots based on:
- Name patterns (e.g., `daily`, `weekly`, `autosnap`)
- Snapshot age
- Retention policies (per-pattern)
- ZFS pool targeting

It supports dry-run mode, recursive deletion, cron-safe locking, and email reporting.

---

## Features

- Pattern matching on snapshot names
- Age-based snapshot cleanup
- Per-pattern retention policies
- Pool-based filtering
- Lock file to prevent overlapping runs
- Dry-run support
- Optional email notifications via `mail`
- Configurable via external config file
- Integrated with systemd timers and services

---

## Requirements

- Python 3
- ZFS command-line utilities
- Optional: `mail` command for email reporting

---

## Installation

1. Place the script on your system:
   ```bash
   sudo cp zfs-killsnaps.py /usr/local/bin/zfs-killsnaps
   sudo chmod +x /usr/local/bin/zfs-killsnaps
   ```

2. Place a YAML config file at `/etc/zfs-killsnaps.yaml`:
   ```yaml
   logfile: /var/log/zfs-killsnaps.log
   lockfile: /var/run/zfs-killsnaps.lock
   email_recipient: you@example.com
   retention_policies:
     daily: 7
     weekly: 30
     monthly: 90
     autosnap: 14
   ```

3. (Optional) Install systemd service and timer:

   - Create the service file at `/etc/systemd/system/zfs-killsnaps.service`:
     ```ini
     [Unit]
     Description=ZFS Snapshot Cleanup
     After=network.target zfs.target

     [Service]
     Type=oneshot
     ExecStart=/usr/local/bin/zfs-killsnaps -p weekly
     Nice=10
     ProtectSystem=full
     ProtectHome=yes
     PrivateTmp=true
     NoNewPrivileges=true
     ```

   - Create the timer file at `/etc/systemd/system/zfs-killsnaps.timer`:
     ```ini
     [Unit]
     Description=Run ZFS Snapshot Cleanup Weekly

     [Timer]
     OnCalendar=Sun 02:00
     Persistent=true

     [Install]
     WantedBy=timers.target
     ```

   - Enable and start the timer:
     ```bash
     sudo systemctl daemon-reload
     sudo systemctl enable --now zfs-killsnaps.timer
     ```

4. If installed via `.deb`, the following maintainer scripts are included:
   - `postinst`: sets up default config and starts the timer
   - `prerm`: stops/disables the systemd units
   - `postrm`: cleans up config/log/lock files on purge

---

## Usage

```bash
zfs-killsnaps [OPTIONS]
```

### Options:
- `-p`, `--pattern`    Match snapshot names (default: `weekly`)
- `-a`, `--age`        Override retention age in days
- `-r`, `--recursive`  Enable recursive deletion
- `-n`, `--dry-run`    Print actions without executing
- `-z`, `--pool`       Limit to specific ZFS pool
- `-c`, `--config`     Use custom config file

---

## Examples

Dry-run of weekly snapshots older than default retention:
```bash
zfs-killsnaps -p weekly -n
```

Delete daily snapshots older than 7 days:
```bash
zfs-killsnaps -p daily -a 7 -r
```

Only affect snapshots in pool `tank`:
```bash
zfs-killsnaps -p autosnap -z tank
```

---

## License

AGPL-3.0-or-later

Copyright (C) 2025 Holstein IT-Solutions  
Author: Michael Bielicki

See [LICENSE](https://www.gnu.org/licenses/agpl-3.0.html) for more.

