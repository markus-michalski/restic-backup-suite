#!/usr/bin/env bash
#
# backup.sh — Restic backup with Docker DB dumps and optional service management
#
# Usage:
#   sudo ./backup.sh [--config /path/to/config.sh] [--dry-run] [--help]
#
# Requires: restic, docker (optional), mysqldump (optional), sftp (optional)
#

set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# Defaults — overridden by config.sh
# Fall back to system-wide install location when no local config.sh exists
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="/etc/restic/config.sh"
DRY_RUN=false

# Runtime state
BACKUP_SUCCESS=false
SERVICES_STOPPED=()
TEMP_DIRS=()

# =============================================================================
# Logging
# =============================================================================

LOG_FILE="/tmp/backup-$(date '+%Y-%m-%d').log"

log() {
    local level="$1"
    shift
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    if [[ "$level" == "ERROR" ]]; then
        echo "$message" | tee -a "$LOG_FILE" >&2
    else
        echo "$message" | tee -a "$LOG_FILE"
    fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# =============================================================================
# Cleanup (runs on EXIT, ERR, INT, TERM)
# =============================================================================

# shellcheck disable=SC2317  # Called via trap
cleanup() {
    local exit_code=$?

    # Remove temp directories
    local tmp_dir
    for tmp_dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
        if [[ -d "$tmp_dir" ]]; then
            rm -rf "$tmp_dir"
            log_info "Removed temp directory: $tmp_dir"
        fi
    done

    # Restart services that were stopped
    restart_services

    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with code: $exit_code"
    fi

    exit "$exit_code"
}

trap cleanup EXIT ERR INT TERM

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [OPTIONS]

Backup server files and databases to a restic repository.

OPTIONS:
    --config FILE   Path to config file (default: ${SCRIPT_DIR}/config.sh)
    --dry-run       Show what would be backed up without running restic
    -h, --help      Show this help message

EXAMPLE:
    sudo $SCRIPT_NAME
    sudo $SCRIPT_NAME --config /etc/restic/config.sh
    sudo $SCRIPT_NAME --dry-run
EOF
}

# =============================================================================
# Config loading
# =============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        log_error "Copy config.example.sh to config.sh and fill in your values."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Apply config to environment
    export RESTIC_PASSWORD_FILE
    export RESTIC_REPOSITORY
    export RESTIC_CACHE_DIR
    export GOMAXPROCS

    # Set log file based on config
    LOG_FILE="${LOG_DIR}/backup-$(date '+%Y-%m-%d').log"
    mkdir -p "$LOG_DIR"
}

# =============================================================================
# Prerequisite checks
# =============================================================================

check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_dependencies() {
    if ! command -v restic &>/dev/null; then
        log_error "restic is not installed or not in PATH."
        exit 1
    fi
    log_info "All required commands found."
}

# =============================================================================
# SSH configuration
# =============================================================================

setup_ssh_config() {
    [[ "$RESTIC_REPOSITORY" != sftp:* ]] && return 0

    log_info "Configuring SSH for SFTP repository..."

    local ssh_dir
    ssh_dir="$(dirname "$SSH_KEY_FILE")"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    local ssh_config_file="${ssh_dir}/config"

    # Write or update the Host block for our backup host.
    # We only touch our specific Host block — existing entries are preserved
    # by writing a separate include file instead of overwriting the main config.
    local include_file="${ssh_dir}/config.d/restic-backup"
    mkdir -p "${ssh_dir}/config.d"

    cat >"$include_file" <<EOF
Host ${SSH_HOST}
    HostName ${SSH_HOSTNAME}
    User ${SSH_USER}
    Port ${SSH_PORT}
    IdentityFile ${SSH_KEY_FILE}
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ConnectTimeout 30
EOF

    chmod 600 "$include_file"

    # Ensure the main config includes the config.d directory
    if ! grep -qF "Include ${ssh_dir}/config.d/*" "$ssh_config_file" 2>/dev/null; then
        # Prepend the Include directive so it takes effect for all hosts
        local tmp_config
        tmp_config="$(mktemp)"
        {
            echo "Include ${ssh_dir}/config.d/*"
            echo ""
            cat "$ssh_config_file" 2>/dev/null || true
        } >"$tmp_config"
        mv "$tmp_config" "$ssh_config_file"
        chmod 600 "$ssh_config_file"
    fi

    if [[ -f "$SSH_KEY_FILE" ]]; then
        chmod 600 "$SSH_KEY_FILE"
    else
        log_warn "SSH key not found: ${SSH_KEY_FILE}"
        log_warn "Generate it with: ssh-keygen -t ed25519 -f ${SSH_KEY_FILE}"
    fi

    log_info "SSH configuration written to: $include_file"
}

test_sftp_connection() {
    [[ "$RESTIC_REPOSITORY" != sftp:* ]] && return 0

    log_info "Testing SFTP connection to ${SSH_HOST}..."

    if sftp -o BatchMode=yes -o ConnectTimeout=10 "${SSH_HOST}" <<<"pwd" >/dev/null 2>&1; then
        log_info "SFTP connection successful."
    else
        log_error "SFTP connection to ${SSH_HOST} failed."
        log_error "Test manually with: sftp ${SSH_HOST}"
        exit 1
    fi
}

# =============================================================================
# Restic repository
# =============================================================================

init_repo_if_needed() {
    log_info "Checking restic repository..."

    if ! restic snapshots >/dev/null 2>&1; then
        log_info "Repository not found — initializing..."
        if restic init; then
            log_info "Repository initialized."
        else
            log_error "Failed to initialize restic repository."
            exit 1
        fi
    else
        log_info "Repository is available."
    fi
}

# =============================================================================
# Service management
# =============================================================================

stop_services() {
    [[ ${#SERVICES_TO_STOP[@]} -eq 0 ]] && return 0

    local service
    for service in "${SERVICES_TO_STOP[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "Stopping service: $service"
            systemctl stop "$service"
            SERVICES_STOPPED+=("$service")
        else
            log_warn "Service not running (skipped): $service"
        fi
    done

    if [[ ${#SERVICES_STOPPED[@]} -gt 0 ]]; then
        sleep "${SERVICE_STOP_WAIT:-2}"
    fi
}

# shellcheck disable=SC2317  # Called via cleanup trap
restart_services() {
    [[ ${#SERVICES_STOPPED[@]} -eq 0 ]] && return 0

    local service
    for service in "${SERVICES_STOPPED[@]}"; do
        log_info "Starting service: $service"
        systemctl start "$service" || log_warn "Failed to start service: $service"
    done

    if [[ ${#SERVICES_STOPPED[@]} -gt 0 ]]; then
        sleep "${SERVICE_START_WAIT:-3}"
    fi
}

# =============================================================================
# Database dumps
# =============================================================================

dump_native_mysql() {
    local dump_dir="$1"

    [[ "${MYSQL_BACKUP_ENABLED:-false}" == "true" ]] || return 0
    command -v mysqldump &>/dev/null || { log_warn "mysqldump not found — skipping native MySQL backup."; return 0; }

    log_info "Dumping native MySQL/MariaDB databases..."

    local db
    while IFS= read -r db; do
        # Skip excluded databases
        local excluded=false
        local excl
        for excl in ${MYSQL_EXCLUDE_DBS:-}; do
            [[ "$db" == "$excl" ]] && excluded=true && break
        done
        [[ "$excluded" == "true" ]] && continue

        local dump_file="${dump_dir}/${db}.sql"
        log_info "Dumping database: $db"
        if mysqldump --single-transaction --quick --lock-tables=false \
            --routines --triggers "$db" >"$dump_file"; then
            log_info "Dumped: $db ($(du -sh "$dump_file" | cut -f1))"
        else
            log_error "Failed to dump database: $db"
            BACKUP_SUCCESS=false
        fi
    done < <(mysql -N -e "SHOW DATABASES;" 2>/dev/null \
        | grep -Ev "^(information_schema|performance_schema|mysql|sys)$")
}

dump_docker_mariadb() {
    local dump_dir="$1"

    [[ ${#DOCKER_MARIADB_CONTAINERS[@]} -eq 0 ]] && return 0
    command -v docker &>/dev/null || { log_warn "docker not found — skipping Docker MariaDB backup."; return 0; }

    local entry container db_user db_name dump_file
    for entry in "${DOCKER_MARIADB_CONTAINERS[@]}"; do
        IFS=: read -r container db_user db_name <<<"$entry"
        dump_file="${dump_dir}/${container}_${db_name}.sql"

        if docker ps --format '{{.Names}}' | grep -Fxq "$container"; then
            log_info "Dumping MariaDB container: ${container}/${db_name}"
            if docker exec \
                -e DB_NAME="$db_name" \
                -e DB_USER="$db_user" \
                "$container" \
                sh -c 'exec mysqldump -u "$DB_USER" -p"$MYSQL_ROOT_PASSWORD" \
                    --single-transaction --quick --routines --triggers --events "$DB_NAME"' \
                >"$dump_file"; then
                log_info "Dumped: ${container}/${db_name} ($(du -sh "$dump_file" | cut -f1))"
            else
                log_error "Failed to dump: ${container}/${db_name}"
                rm -f "$dump_file"
                BACKUP_SUCCESS=false
            fi
        else
            log_warn "Container not running (skipped): $container"
        fi
    done
}

dump_docker_postgres() {
    local dump_dir="$1"

    [[ ${#DOCKER_POSTGRES_CONTAINERS[@]} -eq 0 ]] && return 0
    command -v docker &>/dev/null || { log_warn "docker not found — skipping Docker PostgreSQL backup."; return 0; }

    local entry container db_user db_name dump_file
    for entry in "${DOCKER_POSTGRES_CONTAINERS[@]}"; do
        IFS=: read -r container db_user db_name <<<"$entry"
        dump_file="${dump_dir}/${container}_${db_name}.sql"

        if docker ps --format '{{.Names}}' | grep -Fxq "$container"; then
            log_info "Dumping PostgreSQL container: ${container}/${db_name}"
            if docker exec \
                -e DB_NAME="$db_name" \
                -e DB_USER="$db_user" \
                "$container" \
                sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$DB_USER" --no-password "$DB_NAME"' \
                >"$dump_file"; then
                log_info "Dumped: ${container}/${db_name} ($(du -sh "$dump_file" | cut -f1))"
            else
                log_error "Failed to dump: ${container}/${db_name}"
                rm -f "$dump_file"
                BACKUP_SUCCESS=false
            fi
        else
            log_warn "Container not running (skipped): $container"
        fi
    done
}

# =============================================================================
# Backup
# =============================================================================

run_backup() {
    local db_dump_dir="$1"

    log_info "Starting restic backup..."

    # Build exclude arguments
    local exclude_args=()
    local pattern
    for pattern in "${BACKUP_EXCLUDES[@]+"${BACKUP_EXCLUDES[@]}"}"; do
        exclude_args+=("--exclude" "$pattern")
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would back up:"
        local path
        for path in "${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}"; do
            log_info "  $path"
        done
        log_info "[DRY RUN] Would also include DB dumps from: $db_dump_dir"
        BACKUP_SUCCESS=true
        return 0
    fi

    if restic backup \
        --compression max \
        --exclude-caches \
        --exclude-if-present "${BACKUP_EXCLUDE_IF_PRESENT:-.backupignore}" \
        --one-file-system \
        --verbose \
        "${exclude_args[@]+"${exclude_args[@]}"}" \
        "${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}" \
        "$db_dump_dir" \
        --tag "automated"; then
        log_info "Backup completed successfully."
        BACKUP_SUCCESS=true
    else
        log_error "Backup failed."
        BACKUP_SUCCESS=false
    fi
}

apply_retention_policy() {
    [[ "$BACKUP_SUCCESS" != "true" ]] && return 0

    log_info "Applying retention policy..."

    if restic forget \
        --keep-daily "${RETENTION_KEEP_DAILY:-7}" \
        --keep-weekly "${RETENTION_KEEP_WEEKLY:-4}" \
        --keep-monthly "${RETENTION_KEEP_MONTHLY:-6}" \
        --prune \
        --cleanup-cache; then
        log_info "Retention policy applied."
    else
        log_warn "Retention policy failed — repository may need manual attention."
    fi
}

verify_backup() {
    [[ "$BACKUP_SUCCESS" != "true" ]] && return 0

    log_info "Verifying repository integrity (${REPO_CHECK_SUBSET:-5%} sample)..."

    if restic check --read-data-subset="${REPO_CHECK_SUBSET:-5%}"; then
        log_info "Repository check passed."
    else
        log_warn "Repository check reported issues — run 'restic check' manually."
    fi

    log_info "Backup statistics:"
    restic stats --mode restore-size
    log_info "Latest 5 snapshots:"
    restic snapshots --last 5
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    check_root
    load_config
    check_dependencies
    setup_ssh_config
    test_sftp_connection
    init_repo_if_needed

    # Create temp directory for DB dumps
    local db_dump_dir
    db_dump_dir="$(mktemp -d /tmp/restic-db-dump-XXXXXX)"
    chmod 700 "$db_dump_dir"
    TEMP_DIRS+=("$db_dump_dir")

    stop_services
    dump_native_mysql "$db_dump_dir"
    dump_docker_mariadb "$db_dump_dir"
    dump_docker_postgres "$db_dump_dir"
    run_backup "$db_dump_dir"
    apply_retention_policy
    verify_backup

    if [[ "$BACKUP_SUCCESS" == "true" ]]; then
        log_info "Backup run finished successfully."
        exit 0
    else
        log_error "Backup run finished with errors."
        exit 1
    fi
}

main "$@"
