# TrueNAS SMB to ZFS Migration Script

This script automates the process of migrating user directories from an SMB share to a ZFS pool on TrueNAS. It streamlines the process by performing essential tasks such as creating ZFS datasets with quotas, transferring data from the SMB share to ZFS using rsync, and configuring NFSv4 ACLs to ensure proper access control per user. Additionally, the script supports a dry-run mode for testing and optionally sends email reports upon completion.

This solution is tailored for administrators who need to efficiently migrate a large number of users, enforce data quotas, and ensure that proper permissions are set on the new ZFS datasets. The script works best in environments where user directories are stored in SMB shares and need to be moved to a ZFS-based storage system with strict access controls.

## Key Features:

1. User Directory Migration: Automatically creates ZFS datasets for each user with configurable quotas (e.g., 1G per user).
1. SMB to ZFS Data Transfer: Efficiently copies user data from the SMB share to ZFS datasets using rsync, ensuring data integrity.
1. NFSv4 ACL Management: Configures proper NFSv4 ACLs for each user, based on their UID, to ensure correct permissions on the ZFS datasets.
1. Dry-Run Mode: Simulates the migration process without making any changes to the system. This allows for testing before actually migrating data.
1. User Exclusion: Supports a configurable list of users to exclude from the migration process (e.g., for system accounts or test users).
1. Email Reports: Optionally sends a detailed email report with the migration results, which is useful for keeping stakeholders informed.

## Important Notes:

Usernames and Folder Names Must Match: In the current state of the script, the usernames and the folder names inside the SMB share must match exactly. This is because the script fetches the usernames from the folder names in the SMB share. For example, if you have a user named johndoe on your SMB share, there must be a folder named johndoe in the SMB share. The script will then use this folder name (johndoe) to identify the user and migrate the corresponding data.

Configurable NFSv4 ACL String: The NFSv4 ACL string is customizable, allowing administrators to modify permissions as needed. This string determines the level of access granted to users on their respective datasets. The default string is rwxpDdaARWcCos:fd:allow, which provides full access with various options, including read, write, and execute permissions. More information on NFSv4 ACL strings can be found in the NFSv4 ACL documentation.

## Configuration:

At the beginning of the script, you can configure several variables, such as:

1. MAIN_PATH: Base path for ZFS mounts (e.g., /mnt).
1. MAIN_POOL: Name of the ZFS pool (e.g., tank).
1. MAIN_DATASET: Main dataset name (e.g., userfiles).
1. SOURCE_MOUNT: The mounted SMB share location (e.g., /mnt/oldhomes).
1. QUOTA: User quota for storage (e.g., 1G per user).
1. LOGFILE: Path to the log file (e.g., ./migration.log).
1. MAILTO: Optional email address for sending a report upon completion.
1. SKIP_USERS: A comma-separated list of users to exclude from the migration process.
1. NFS4_ACL_STRING: The NFSv4 ACL string used to configure permissions for each user on their ZFS dataset. The default value is rwxpDdaARWcCos:fd:allow.

## Usage:

* Configure the script with your desired settings (e.g., paths, quotas, email).
* Run the script. For a dry-run simulation (no changes made), use the --dry-run flag.
* Monitor the script output in the terminal and check the log file for detailed progress.
* Optionally, an email report will be sent if you configure the MAILTO variable.

## Examples
> ./migrate_smb_to_zfs.sh

For a dry run:
> ./migrate_smb_to_zfs.sh --dry-run

## License:
This script is licensed under the GNU Affero General Public License v3.0.
