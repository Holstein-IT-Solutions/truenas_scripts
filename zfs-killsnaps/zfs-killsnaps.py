#!/usr/bin/env python3

# This file is part of the ZFS Snapshot Cleanup Tool.
# Copyright (C) 2025 Holstein IT-Solutions
# Author: Michael Bielicki
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
ZFS Snapshot Cleanup Tool

Description:
    This script deletes ZFS snapshots based on a naming pattern and optional age limit.
    It supports per-pattern retention policies, recursive deletion, dry-run mode,
    email notifications, logging, and cron safety via lock files.

Usage:
    ./zfs-killsnaps.py [options]

Options:
    -p, --pattern     Match snapshot names (default: 'weekly')
    -a, --age         Age in days to override policy (e.g., -a 10)
    -r, --recursive   Enable recursive destroy
    -n, --dry-run     Show what would be destroyed, do not execute
    -z, --pool        Limit to specific pool (e.g., 'tank')
    -c, --config      Path to YAML config file (default: /etc/zfs-killsnaps.yaml)
"""

import argparse
import subprocess
import logging
import os
import sys
import shutil
import yaml
from datetime import datetime

DEFAULT_CONFIG_PATH = "/etc/zfs-killsnaps.yaml"

DEFAULT_CONFIG = {
    'logfile': '/var/log/zfs-killsnaps.log',
    'lockfile': '/var/run/zfs-killsnaps.lock',
    'email_recipient': 'admin@example.com',
    'retention_policies': {
        'daily': 7,
        'weekly': 30,
        'monthly': 90,
        'autosnap': 14
    }
}

def load_config(path):
    if not os.path.exists(path):
        return DEFAULT_CONFIG
    with open(path, 'r') as f:
        data = yaml.safe_load(f)
    config = DEFAULT_CONFIG.copy()
    config.update(data or {})
    return config

def run_cmd(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout.strip(), result.stderr.strip(), result.returncode

def parse_creation_date(date_str):
    return datetime.strptime(date_str, "%a %b %d %H:%M %Y")

def is_older_than(creation_str, days):
    creation_time = parse_creation_date(creation_str)
    return (datetime.now() - creation_time).days >= days

def load_snapshots(pattern, pool=None):
    cmd = "zfs list -H -t snapshot"
    out, err, code = run_cmd(cmd)
    if code != 0:
        logging.error(f"Failed to list snapshots: {err}")
        sys.exit(1)
    lines = out.splitlines()
    snapshots = []
    for line in lines:
        name = line.split('\t')[0]
        if pattern in name and (not pool or name.startswith(pool + '@') or name.startswith(pool + '/')):
            snapshots.append(name)
    return snapshots

def get_snapshot_creation(snapshot):
    cmd = f"zfs get -H -o value creation {snapshot}"
    out, err, code = run_cmd(cmd)
    if code != 0:
        logging.warning(f"Could not get creation time for {snapshot}: {err}")
        return None
    return out

def send_email(logfile, recipient):
    if shutil.which("mail") and os.path.exists(logfile):
        with open(logfile) as f:
            subprocess.run(["mail", "-s", "ZFS Snapshot Cleanup Report", recipient], input=f.read(), text=True)

def lock_or_exit(lockfile):
    if os.path.exists(lockfile):
        logging.error("Lock file exists. Script already running.")
        sys.exit(1)
    open(lockfile, 'w').close()
    return lambda: os.remove(lockfile)

def get_policy_age(pattern, policies):
    return policies.get(pattern, 0)

def cleanup_snapshots(pattern, age_days, recursive, dry_run, pool, config):
    snapshots = load_snapshots(pattern, pool)
    if not snapshots:
        logging.info(f"No snapshots matching '{pattern}' found.")
        return

    destroyed = 0
    for snap in snapshots:
        creation_str = get_snapshot_creation(snap)
        if not creation_str or not is_older_than(creation_str, age_days):
            continue

        logging.info(f"Found snapshot: {snap} (created {creation_str})")
        if dry_run:
            logging.info(f"[Dry-run] Would destroy {snap}")
        else:
            cmd = f"zfs destroy {'-r' if recursive else ''} {snap}"
            _, err, code = run_cmd(cmd)
            if code == 0:
                logging.info(f"Destroyed: {snap}")
                destroyed += 1
            else:
                logging.error(f"Failed to destroy {snap}: {err}")
    logging.info(f"Total snapshots destroyed: {destroyed}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="ZFS Snapshot Cleanup Tool")
    parser.add_argument("-p", "--pattern", default="weekly", help="Snapshot name pattern")
    parser.add_argument("-a", "--age", type=int, help="Override age in days")
    parser.add_argument("-r", "--recursive", action="store_true", help="Recursive destroy")
    parser.add_argument("-n", "--dry-run", action="store_true", help="Dry-run mode")
    parser.add_argument("-z", "--pool", help="Limit to specific ZFS pool")
    parser.add_argument("-c", "--config", default=DEFAULT_CONFIG_PATH, help="Path to YAML config file")
    args = parser.parse_args()

    config = load_config(args.config)

    logging.basicConfig(
        filename=config['logfile'],
        level=logging.INFO,
        format='%(asctime)s %(levelname)s: %(message)s'
    )

    unlock = lock_or_exit(config['lockfile'])

    try:
        age_days = args.age or get_policy_age(args.pattern, config['retention_policies'])
        cleanup_snapshots(
            pattern=args.pattern,
            age_days=int(age_days),
            recursive=args.recursive,
            dry_run=args.dry_run,
            pool=args.pool,
            config=config
        )
    finally:
        unlock()
        send_email(config['logfile'], config['email_recipient'])
