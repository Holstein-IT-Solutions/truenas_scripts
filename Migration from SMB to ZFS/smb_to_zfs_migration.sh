#!/bin/bash
##########################################################################################
# ----------------------------------------------------------------------------------------
# Holstein IT-Solutions Inh. Benedict Schultz
# Copyright (C) 2025 Benedict Schultz
# Authors: Marek Slodkowski, Michael Bielicki
#
# This program is free software: you can redistribute it and/or modify it under the terms
# of the Affero General Public License (AGPL), Version 3, as distributed with this program.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY,
# not even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the Affero General Public License, Version 3, for more details.
#
# You should have received a copy of the Affero General Public License along with this
# program. If not, see <http://www.gnu.org/licenses/agpl-3.0.html>.
#
# ----------------------------------------------------------------------------------------
# TrueNAS SMB to ZFS Migration with ACL Support
# ----------------------------------------------------------------------------------------
#
# This script migrates user directories from an SMB share to a ZFS pool on TrueNAS,
# ensuring data integrity, access permissions, and storage quotas. It is ideal for
# administrators transitioning SMB-based user folders to a modern ZFS filesystem with
# NFSv4 ACLs, particularly in Active Directory (AD) environments.
#
# Main Features:
# - Creates ZFS datasets for each user folder with individual storage quotas.
# - Copies data securely using rsync with progress indication.
# - Converts SMB ACLs (via smbcacls) to NFSv4 ACLs for TrueNAS.
# - Supports Active Directory users and groups for precise permission mapping.
# - Provides a dry-run mode for simulation without changes.
# - Allows skipping specified folders (e.g., test or guest accounts).
# - Verifies the SMB share mount status before migration.
# - Logs all steps in detail to a log file.
# - Optionally sends an email report upon completion.
# - Handles errors (e.g., missing ACLs, non-existent folders) with clear messages.
#
# Prerequisites:
# - TrueNAS system with a ZFS pool (tested with TrueNAS Scale 24.10.2).
# - SMB share must be mounted with the following mount flags before running the script
#   (e.g., with "mount -t cifs //192.168.1.1/smbshare /mnt/smbshare -o username=administrator@MYDOMAIN,iocharset=utf8,acl,noperm,cifsacl").
# - For Active Directory environments: TrueNAS must be configured in AD to resolve users and groups correctly.
#   
# Note: Review the configuration variables carefully before running.
##########################################################################################

### === CONFIGURATION ===
#
# The following variables control the script's behavior. Adjust them to your environment.
# Each variable is described in detail to ensure easy and safe configuration.

# Base path where ZFS datasets are mounted.
# Typically /mnt on TrueNAS systems.
# Example: /mnt
# Note: Change this only if your system uses a different mount point.
# Error: An incorrect path leads to dataset creation failures.
MAIN_PATH="/mnt"

# Name of the ZFS pool where datasets are created.
# This is the main pool of your TrueNAS system.
# Example: tank, pool1
# Note: Run `zpool list` to find your pool name.
# Error: A non-existent pool causes the script to abort.
MAIN_POOL="tank"

# Name of the main dataset under which user datasets are created.
# The resulting dataset will be MAIN_POOL/MAIN_DATASET (e.g., tank/userfiles).
# Example: userfiles, homes
# Note: Choose a clear name reflecting the structure.
# Error: Special characters or overly long names may cause issues.
MAIN_DATASET="userfiles"

# Local path where the SMB share is mounted.
# This is the source of the user folders to be migrated.
# Example: /mnt/home, /mnt/smb
# Note: Ensure the share is mounted before running the script
#       (e.g., with `mount -t cifs //192.168.1.1/share /mnt/home ...`).
# Error: If the path does not exist or is not mounted, the script aborts.
SMB_MOUNTED_IN="/mnt/home"

# Network path of the SMB share for smbcacls to read ACLs.
# Format: //SERVER/SHARE
# Example: //192.168.1.1/smbshare, //fileserver/homes
# Note: This must exactly match the mounted share.
# Error: An incorrect path leads to ACL retrieval failures.
SMB_ACL_ROOT="//192.168.1.1/smbshare"

# Username for accessing the SMB share (for smbcacls).
# Format: user@domain (for AD environments) or just user (local).
# Example: Administrator@HITS, smbuser
# Note: The user must have read access to ACLs.
# Error: Incorrect credentials cause authentication failures.
SMB_AUTH_USER="administrator@HITS"

# Password for the SMB user in plaintext.
# Example: myPassword123
# Note: Replace "********" with the actual password.
#       For security, remove the password after migration or use a credentials file
#       (future version).
# Error: An incorrect password causes authentication failures.
SMB_AUTH_PASS="********"

# Storage quota for each user dataset.
# Format: Number with unit (e.g., 1G, 500M, 10T).
# Example: 1G (1 Gigabyte), 100M (100 Megabyte)
# Note: Ensure the pool has sufficient capacity.
# Error: Excessive quotas may prevent dataset creation.
QUOTA="1G"

# Path to the log file where all actions are recorded.
# Example: ./migration.log, /var/log/migration.log
# Note: The path must be writable. Relative paths are relative to the script's
#       execution directory.
# Error: A non-writable path causes logging failures.
LOGFILE="./migration.log"

# Email address for the completion report (optional).
# Example: admin@example.com
# Note: Leave empty ("") to disable email sending.
#       The system must support `mail` and be properly configured.
# Error: An invalid address or missing mail configuration causes errors.
MAILTO=""

# Active Directory domain for resolving users and groups.
# Example: MYDOMAIN
# Note: Must match the domain in SMB_AUTH_USER.
#       For non-AD environments, leave empty or adjust.
# Error: An incorrect domain causes issues with ACL conversion.
AD_DOMAIN="MYDOMAIN"

# Comma-separated list of folders to skip.
# Example: test,guest,admin
# Note: Case-sensitive. Folders must exactly match the directory names in the SMB share.
# Error: Incorrect names cause folders to be migrated erroneously.
SKIP_FOLDERS="test,guest,admin"

### === DRY-RUN CHECK ===

DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    echo ">>> [>] Dry-run mode activated"
    echo ">>> [>] Dry-run mode activated" >> "$LOGFILE"
fi

### === HELPER FUNCTIONS ===

# LOG: Logs messages to console and file
#
# Purpose:
# - Outputs a message to both the console and the log file.
# - Used for tracking script progress, errors, and status updates.
# - Aids in debugging and monitoring.
#
# Parameters:
# - $1: The message to log (e.g., "[✓] Dataset created").
#
# Flow:
# - Prints the message to the console (using `echo`).
# - Appends the message to the log file (defined in $LOGFILE).
#
# Error Cases:
# - If $LOGFILE is not writable, writing fails.
# - Solution: Ensure $LOGFILE path exists and has write permissions
#   (e.g., `chmod u+w ./migration.log`).
#
# Example:
# - `LOG ">>> Starting migration"` writes to console and ./migration.log.
LOG() {
    echo "$1"
    echo "$1" >> "$LOGFILE"
}

# RUN: Executes commands or simulates them in dry-run mode
#
# Purpose:
# - Safely executes commands (e.g., `zfs create`, `rsync`).
# - In dry-run mode, commands are logged but not executed.
# - Standardizes command execution in the script.
#
# Parameters:
# - $@: The full command with arguments (e.g., `zfs set acltype=nfsv4 tank/userfiles`).
#
# Flow:
# - Checks if $DRY_RUN is set to `true`.
# - In dry-run: Logs the command prefixed with "[dry-run]".
# - In real run: Executes the command using `eval`.
#
# Error Cases:
# - In dry-run: No errors, as nothing is executed.
# - In real run: Errors depend on the command (e.g., `zfs create` fails if the pool
#   does not exist).
# - The return code ($?) is checked to report errors.
#
# Example:
# - `RUN zfs create tank/userfiles` creates the dataset or logs
#   "[dry-run] zfs create tank/userfiles".
RUN() {
    if $DRY_RUN; then
        LOG "    [dry-run] $*"
    else
        eval "$@"
    fi
}

# SHOULD_SKIP_FOLDER: Checks if a folder should be skipped
#
# Purpose:
# - Filters folders based on the $SKIP_FOLDERS list.
# - Prevents migration of test or system folders (e.g., "guest").
#
# Parameters:
# - $1: The folder name (e.g., "user1", "test").
#
# Flow:
# - Compares the folder name against the comma-separated $SKIP_FOLDERS list.
# - Returns `true` if the folder is in the list, `false` otherwise.
#
# Error Cases:
# - Incorrect case sensitivity leads to folders not being recognized.
# - Solution: Ensure $SKIP_FOLDERS exactly matches folder names in the SMB share.
#
# Example:
# - If $SKIP_FOLDERS="test,guest" and $1="test", returns `true`, and the folder is skipped.
SHOULD_SKIP_FOLDER() {
    local USER_FOLDER="$1"
    [[ ",$SKIP_FOLDERS," == *",$USER_FOLDER,"* ]]
}

# SEND_REPORT: Sends an email report with the log
#
# Purpose:
# - Sends the log file via email to the address specified in $MAILTO.
# - Allows administrators to review migration status remotely.
#
# Parameters:
# - None (uses $MAILTO and $LOGFILE from configuration).
#
# Flow:
# - Checks if $MAILTO is non-empty.
# - If set, sends the log file using the `mail` command.
# - Logs the sending status.
#
# Error Cases:
# - If $MAILTO is empty, nothing happens (intended behavior).
# - If `mail` is not configured or $MAILTO is invalid, sending fails
#   (error not explicitly handled).
# - Solution: Configure `mail` on TrueNAS or leave $MAILTO empty.
#
# Example:
# - If $MAILTO="admin@example.com", sends ./migration.log to that address.
SEND_REPORT() {
    if [ -n "$MAILTO" ]; then
        mail -s "TrueNAS Migration Report" "$MAILTO" < "$LOGFILE"
        LOG ">>> [✓] Report sent to $MAILTO."
    fi
}

# SET_ACL: Migrates SMB ACLs to NFSv4 ACLs for a ZFS dataset
#
# Purpose:
# - Configures a ZFS dataset for NFSv4 ACLs and transfers permissions from the SMB share.
# - Ensures user and group permissions (e.g., from AD) are correctly applied.
#
# Parameters:
# - $1: Path to the ZFS dataset (e.g., /mnt/tank/userfiles/user1).
# - $2: Folder name (e.g., user1).
#
# Flow:
# 1. Validates parameter count (must be exactly 2).
# 2. Sets ZFS properties for NFSv4 ACLs:
#    - `acltype=nfsv4`: Enables NFSv4 ACLs.
#    - `xattr=sa`: Stores extended attributes securely.
#    - `aclmode=passthrough`: Allows ACL inheritance.
# 3. Retrieves SMB ACLs using `smbcacls` from the SMB share.
# 4. Filters relevant ACLs (e.g., HITS\user1) with `grep`.
# 5. Converts SMB ACLs to NFSv4 format:
#    - Resolves AD users/groups to IDs (using `getent`).
#    - Maps permissions (FULL, READ, MODIFY) to NFSv4 rights.
# 6. Applies NFSv4 ACLs using `nfs4xdr_setfacl`.
# 7. Verifies applied ACLs with `nfs4xdr_getfacl` and stores them in /tmp.
#
# Error Cases:
# - Incorrect parameter count: Aborts with an error message.
# - ZFS settings fail: If the dataset does not exist or lacks write permissions,
#   logs an error.
# - smbcacls errors: Authentication issues or non-existent folders cause abort.
# - No ACLs: If no valid ACLs are found, aborts.
# - Unknown AD entities: Skipped with a warning logged.
#
# Example:
# - `SET_ACL /mnt/tank/userfiles/user1 user1`:
#   - Configures dataset tank/userfiles/user1.
#   - Reads ACLs from //192.168.1.1/smbshare/user1.
#   - Sets NFSv4 ACLs like `user:1001:rwxpDdaARWcCos:fd:allow`.
#   - Stores ACLs in /tmp/nfs4xdr_getfacl_user1.txt.
SET_ACL() {
    if [ "$#" -ne 2 ]; then
        LOG "   [✗] Error: SET_ACL expects exactly 2 parameters (USERPATH, USER_FOLDER), but $# received!"
        return 1
    fi

    local USERPATH="$1"
    local USER_FOLDER="$2"

    LOG "   -> Setting ACLs for folder $USER_FOLDER"

    # Define the dataset path without /mnt
    local DATASET_PATH="${MAIN_POOL}/${MAIN_DATASET}/${USER_FOLDER}"

    # Full mount path for the dataset (including /mnt)
    local MOUNT_PATH="${MAIN_PATH}/${DATASET_PATH}"

    LOG "   -> Checking ACLs for dataset: $DATASET_PATH"

    # Set ZFS ACL properties, without /mnt
    RUN zfs set acltype=nfsv4 "$DATASET_PATH"
    if [ $? -ne 0 ]; then
        LOG "   [✗] Error setting ACL type for $USER_FOLDER on $DATASET_PATH"
    fi

    RUN zfs set xattr=sa "$DATASET_PATH"
    if [ $? -ne 0 ]; then
        LOG "   [✗] Error setting xattr=sa for $USER_FOLDER on $DATASET_PATH"
    fi

    RUN zfs set aclmode=passthrough "$DATASET_PATH"
    if [ $? -ne 0 ]; then
        LOG "   [✗] Error setting aclmode=passthrough for $USER_FOLDER on $DATASET_PATH"
    fi

    # Retrieve ACLs with smbcacls
    LOG "   -> Reading ACLs for $USER_FOLDER with smbcacls"
    smbcacls "$SMB_ACL_ROOT" "$USER_FOLDER" -U "$SMB_AUTH_USER%$SMB_AUTH_PASS" > "/tmp/raw_acls_$USER_FOLDER.txt" 2> "/tmp/smbcacls_err_$USER_FOLDER.txt"
    grep "^ACL:${AD_DOMAIN}\\\[^\:]*:" "/tmp/raw_acls_$USER_FOLDER.txt" > "/tmp/acls_$USER_FOLDER.txt"
    if [ $? -ne 0 ]; then
        LOG "   [✗] Error filtering ACLs for $USER_FOLDER, see /tmp/raw_acls_$USER_FOLDER.txt and /tmp/smbcacls_err_$USER_FOLDER.txt"
        cat "/tmp/smbcacls_err_$USER_FOLDER.txt" >> "$LOGFILE"
        return 1
    fi
    if [ ! -s "/tmp/acls_$USER_FOLDER.txt" ]; then
        LOG "   [✗] No ACLs found for $USER_FOLDER, see /tmp/raw_acls_$USER_FOLDER.txt"
        cat "/tmp/raw_acls_$USER_FOLDER.txt" >> "$LOGFILE"
        return 1
    fi

    # Convert ACLs
    rm -f "/tmp/nfs4_acls_$USER_FOLDER.txt"
    while read -r LINE; do
        if [[ "$LINE" =~ ^ACL:(${AD_DOMAIN}\\[^:]+):ALLOWED/[^/]+/(.+)$ ]]; then
            ENTITY="${BASH_REMATCH[1]}"
            PERM="${BASH_REMATCH[2]}"
            NAME=$(echo "$ENTITY" | cut -d'\' -f2)
            if getent passwd "$ENTITY" >/dev/null; then
                TYPE="user"
                ID=$(getent passwd "$ENTITY" | cut -d: -f3)
            elif getent group "$ENTITY" >/dev/null; then
                TYPE="group"
                ID=$(getent group "$ENTITY" | cut -d: -f3)
            else
                LOG "   [!] Skipping unknown entity: $ENTITY"
                continue
            fi
            case "$PERM" in
                "FULL") NFS4="rwxpDdaARWcCos:fd:allow" ;;
                "READ") NFS4="r-x---a-R-c---:fd:allow" ;;
                "MODIFY") NFS4="rwxpDaARWcCos:fd:allow" ;;
                *) LOG "   [!] Skipping unknown permission: $PERM"; continue ;;
            esac
            echo "$TYPE:$ID:$NFS4" >> "/tmp/nfs4_acls_$USER_FOLDER.txt"
            LOG "   [✓] Converted: $TYPE:$ID:$NFS4"
        fi
    done < "/tmp/acls_$USER_FOLDER.txt"

    # Apply ACLs
    if [ -s "/tmp/nfs4_acls_$USER_FOLDER.txt" ]; then
        while read -r ACL; do
            RUN nfs4xdr_setfacl -a "$ACL" "$MOUNT_PATH"
            if [ $? -eq 0 ]; then
                LOG "   [✓] NFSv4 ACL set: $ACL"
            else
                LOG "   [✗] Error setting: $ACL"
            fi
        done < "/tmp/nfs4_acls_$USER_FOLDER.txt"
    else
        LOG "   [✗] No NFSv4 ACLs to set for $USER_FOLDER"
        return 1
    fi

    # Verify NFSv4 ACLs
    RUN nfs4xdr_getfacl "$MOUNT_PATH" > "/tmp/nfs4xdr_getfacl_$USER_FOLDER.txt"
    LOG "   [✓] NFSv4 ACLs verified: see /tmp/nfs4xdr_getfacl_$USER_FOLDER.txt"
}

### === START MESSAGE ===

LOG ">>> Starting the migration script"
LOG ">>> Source: $SMB_MOUNTED_IN"
LOG ">>> Target: ${MAIN_POOL}/${MAIN_DATASET}"
$DRY_RUN && LOG ">>> Mode: Dry-run (simulation)"
LOG ">>> Folders to skip: $SKIP_FOLDERS"

# Check if the source directory is mounted
if ! mountpoint -q "$SMB_MOUNTED_IN"; then
    LOG "   [✗] Error: Source $SMB_MOUNTED_IN is not mounted. Aborting."
    exit 1
fi

### === STEP 1: CHECK/CREATE MAIN DATASET ===

# Set full names for the root dataset and mount path
ROOT_FULL="${MAIN_POOL}/${MAIN_DATASET}"
ROOT_MOUNT="${MAIN_PATH}/${ROOT_FULL}"

# Check if the main dataset exists; create it if not
if ! zfs list "$ROOT_FULL" >/dev/null 2>&1; then
    LOG "-> Creating main dataset: $ROOT_FULL"
    RUN zfs create "$ROOT_FULL"
else
    LOG "-> Main dataset $ROOT_FULL already exists."
fi

### === STEP 2: CREATE SUBDATASETS ===

# Gather list of subfolders in the source directory
USER_FOLDERS=()
for FOLDER in "$SMB_MOUNTED_IN"/*; do
    [ -d "$FOLDER" ] && USER_FOLDERS+=("$FOLDER")
done

# Process each directory
for SRC_FOLDER in "${USER_FOLDERS[@]}"; do
    USER_FOLDER=$(basename "$SRC_FOLDER")

    if SHOULD_SKIP_FOLDER "$USER_FOLDER"; then
        LOG "   [>] Folder '$USER_FOLDER' is in SKIP_FOLDERS. Skipping."
        continue
    fi

    SUBDATASET="${ROOT_FULL}/${USER_FOLDER}"
    SUBMOUNT="${MAIN_PATH}/${SUBDATASET}"

    LOG "-> Processing folder '$USER_FOLDER'"

    # Create subdataset only if it does not exist
    if zfs list "$SUBDATASET" >/dev/null 2>&1; then
        LOG "   [!] Subdataset $SUBDATASET already exists. Skipping creation."
        continue
    fi

    LOG "   -> Creating subdataset $SUBDATASET with quota $QUOTA"
    RUN zfs create -o quota="$QUOTA" "$SUBDATASET"
    LOG "   [✓] Subdataset created for $USER_FOLDER."

    # Call SET_ACL
    SET_ACL "$SUBMOUNT" "$USER_FOLDER"

done

LOG ">>> [✓] All subdatasets processed."

### === STEP 3: COPY DATA ===

# Copy data from source to target
for SRC_FOLDER in "${USER_FOLDERS[@]}"; do
    USER_FOLDER=$(basename "$SRC_FOLDER")

    if SHOULD_SKIP_FOLDER "$USER_FOLDER"; then
        continue
    fi

    DST_MOUNT="${MAIN_PATH}/${ROOT_FULL}/${USER_FOLDER}"

    # Target directory must exist
    if [ ! -d "$DST_MOUNT" ]; then
        LOG "   [✗] Target directory for '$USER_FOLDER' is missing. Skipping copy."
        continue
    fi

    LOG "-> Copying files for folder '$USER_FOLDER'"

    # Perform copy or log in dry-run
    if $DRY_RUN; then
        LOG "    [dry-run] rsync -a --info=progress2 '$SRC_FOLDER/' '$DST_MOUNT/'"
    else
        rsync -a --info=progress2 "$SRC_FOLDER/" "$DST_MOUNT/"
        if [ $? -eq 0 ]; then
            LOG "   [✓] Files successfully copied for $USER_FOLDER"
        else
            LOG "   [✗] Error copying files for $USER_FOLDER"
        fi
    fi

done

LOG ">>> [✓] Migration completed."

### === STEP 4: SEND REPORT (OPTIONAL) ===
SEND_REPORT