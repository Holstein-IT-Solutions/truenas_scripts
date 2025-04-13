# TrueNAS SMB to ZFS Migration Script

## English

This script migrates user directories from an SMB share to a ZFS pool on TrueNAS, preserving data integrity, access permissions, and applying storage quotas. It is designed for administrators transitioning SMB-based user folders to a modern ZFS filesystem with NFSv4 ACLs, especially in Active Directory (AD) environments.

### Features
- Creates ZFS datasets for each user folder with customizable storage quotas.
- Copies data securely using `rsync` with progress indication.
- Converts SMB ACLs (via `smbcacls`) to NFSv4 ACLs for TrueNAS.
- Supports Active Directory users and groups for accurate permission mapping.
- Offers a dry-run mode to simulate actions without changes.
- Skips specified folders (e.g., test or guest accounts).
- Verifies SMB share mount status before starting.
- Logs all actions in detail to a file.
- Optionally sends an email report upon completion.
- Handles errors (e.g., missing ACLs, non-existent folders) with clear messages.

### Prerequisites
- TrueNAS system with a ZFS pool (tested with TrueNAS Scale 24.10.2).
- SMB share must be mounted before running the script (e.g., `mount -t cifs //192.168.1.1/smbshare /mnt/home -o username=administrator@MYDOMAIN,iocharset=utf8,acl,noperm,cifsacl`).
- For AD environments: TrueNAS must be configured in Active Directory to resolve users and groups correctly.

### Configuration
The script is configured via variables at the top of `migration.sh`. Below is a summary:

| Variable         | Description                                                                 | Example                     |
|------------------|-----------------------------------------------------------------------------|-----------------------------|
| `MAIN_PATH`      | Base path for ZFS mounts (typically `/mnt`).                                | `/mnt`                      |
| `MAIN_POOL`      | ZFS pool name (run `zpool list` to find it).                                | `tank`                      |
| `MAIN_DATASET`   | Main dataset name (forms `MAIN_POOL/MAIN_DATASET`).                         | `userfiles`                 |
| `SMB_MOUNTED_IN` | Local path where SMB share is mounted.                                      | `/mnt/home`                 |
| `SMB_ACL_ROOT`   | SMB share network path for ACL retrieval.                                   | `//192.168.1.1/smbshare`    |
| `SMB_AUTH_USER`  | Username for SMB access (format: `user@domain` for AD).                     | `administrator@MYDOMAIN`    |
| `SMB_AUTH_PASS`  | Password for SMB user (replace `********`).                                 | `********`                  |
| `QUOTA`          | Storage quota per user dataset (e.g., `1G`, `500M`).                        | `1G`                        |
| `LOGFILE`        | Path to log file (must be writable).                                        | `./migration.log`           |
| `MAILTO`         | Email for report (leave empty to disable).                                  | `admin@example.com`         |
| `AD_DOMAIN`      | AD domain for user/group resolution.                                        | `MYDOMAIN`                  |
| `SKIP_FOLDERS`   | Comma-separated list of folders to skip (case-sensitive).                   | `test,guest,admin`          |

**Note**: Replace `SMB_AUTH_PASS` with the actual password and ensure the SMB share is mounted before running.

### Usage
1. Save the script as `migration.sh` and make it executable:
   ```bash
   chmod +x migration.sh