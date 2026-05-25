#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables are used by backup.sh / restore.sh via source
#
# config.example.sh — Configuration template for restic-backup-suite
#
# SETUP:
#   cp config.example.sh config.sh
#   chmod 600 config.sh       # Restrict access — contains sensitive paths
#   nano config.sh            # Fill in your values
#
# config.sh is gitignored and will never be committed.
#

# =============================================================================
# RESTIC CORE
# =============================================================================

# Path to a file containing the restic repository password (one line, no newline).
# Permissions should be 400 or 600 (readable only by owner/root).
RESTIC_PASSWORD_FILE="/etc/restic/password.txt"

# Restic repository location.
# Examples:
#   SFTP (Hetzner Storage Box):  "sftp:myhost:/path/to/repo"
#   Local:                       "/mnt/backup/restic-repo"
#   S3:                          "s3:s3.amazonaws.com/bucket-name"
#   Backblaze B2:                "b2:bucket-name:/path"
#   REST server:                 "rest:http://localhost:8000/"
RESTIC_REPOSITORY="sftp:myhost:/backup/restic"

# Local cache directory for restic metadata.
RESTIC_CACHE_DIR="${HOME}/.cache/restic"

# Number of CPU cores to use for restic compression/hashing.
# Set to 0 to use all available cores.
GOMAXPROCS=2

# =============================================================================
# SFTP / SSH (only needed when using sftp:// repository)
# =============================================================================

# SSH Host alias — must match the Host entry in ~/.ssh/config (or /root/.ssh/config).
# restic uses this alias for the sftp connection.
SSH_HOST="myhost"

# Real hostname or IP of the remote server.
SSH_HOSTNAME="storage.example.com"

# SSH port (Hetzner Storage Box uses 23, standard SSH is 22).
SSH_PORT=22

# SSH username on the remote server.
SSH_USER="myuser"

# Absolute path to the SSH private key used for authentication.
SSH_KEY_FILE="${HOME}/.ssh/id_ed25519"

# Path on the remote server where the known_hosts file is stored.
# Using a dedicated file avoids polluting the system known_hosts.
# Leave empty to use the default (~/.ssh/known_hosts).
SSH_KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts_backup"

# =============================================================================
# LOGGING
# =============================================================================

# Directory where log files are written.
# The scripts create dated log files: backup-YYYY-MM-DD.log / restore-YYYY-MM-DD.log
LOG_DIR="/var/log/restic"

# =============================================================================
# BACKUP PATHS
# =============================================================================

# Directories to include in the backup.
# Add one path per line inside the parentheses.
BACKUP_PATHS=(
    "/var/www"
    "/etc"
    "/home"
    # "/opt/myapp"
    # "/srv"
)

# =============================================================================
# BACKUP EXCLUSIONS
# =============================================================================

# Patterns to exclude from the backup.
# Supports glob patterns — see `man restic` for details.
BACKUP_EXCLUDES=(
    "*.log"
    "*/tmp/*"
    "*/cache/*"
    "*/.git/*"
    "*/node_modules/*"
    "*/vendor/*"
)

# Files/directories containing this filename are excluded entirely (like .gitignore for backups).
BACKUP_EXCLUDE_IF_PRESENT=".backupignore"

# =============================================================================
# RETENTION POLICY
# =============================================================================

# How many daily snapshots to keep.
RETENTION_KEEP_DAILY=7

# How many weekly snapshots to keep.
RETENTION_KEEP_WEEKLY=4

# How many monthly snapshots to keep.
RETENTION_KEEP_MONTHLY=6

# =============================================================================
# REPOSITORY HEALTH CHECK
# =============================================================================

# Percentage of pack files to read and verify after each successful backup.
# "5%" is a good default — low overhead, catches corruption over time.
# Set to "100%" for a full check (slow on large repos).
REPO_CHECK_SUBSET="5%"

# =============================================================================
# NATIVE (NON-DOCKER) MYSQL / MARIADB
# =============================================================================

# Set to "true" to enable dumping MySQL/MariaDB databases installed natively
# on the host (not in Docker). Requires mysqldump in PATH and root access.
MYSQL_BACKUP_ENABLED=false

# Databases to exclude from native MySQL dumps.
# The system databases are always excluded regardless.
MYSQL_EXCLUDE_DBS="information_schema performance_schema mysql sys"

# =============================================================================
# DOCKER MARIADB / MYSQL CONTAINERS
# =============================================================================

# List of Docker MariaDB/MySQL containers to dump before backup.
# Format: "container_name:db_user:db_name"
#
# The container must have MYSQL_ROOT_PASSWORD set as an environment variable.
# The dump is created inside the container via `docker exec`.
#
# Example:
#   DOCKER_MARIADB_CONTAINERS=(
#       "my-mariadb:root:app_db"
#       "another-db:root:shop_db"
#   )
DOCKER_MARIADB_CONTAINERS=(
    # "mycontainer:root:mydb"
)

# =============================================================================
# DOCKER POSTGRESQL CONTAINERS
# =============================================================================

# List of Docker PostgreSQL containers to dump before backup.
# Format: "container_name:db_user:db_name"
#
# The container must have POSTGRES_PASSWORD set as an environment variable.
#
# Example:
#   DOCKER_POSTGRES_CONTAINERS=(
#       "my-postgres:postgres:app_db"
#   )
DOCKER_POSTGRES_CONTAINERS=(
    # "mycontainer:postgres:mydb"
)

# =============================================================================
# MANAGED SERVICES (optional stop/start around backup)
# =============================================================================

# Systemd services to stop before backup and restart after.
# Useful for services that require a clean state for consistent backups
# (e.g., a sync server that holds open file locks).
# Leave empty to skip.
#
# Example:
#   SERVICES_TO_STOP=("myapp" "myapp-worker")
SERVICES_TO_STOP=()

# Seconds to wait after stopping services before starting the backup.
SERVICE_STOP_WAIT=2

# Seconds to wait after starting services to let them initialize.
SERVICE_START_WAIT=3
