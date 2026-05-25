#!/usr/bin/env bash
#
# restore.sh — Interactive restore from a restic repository
#
# Usage:
#   sudo ./restore.sh [--config /path/to/config.sh] [--snapshot SNAPSHOT_ID] [--help]
#
# Requires: restic
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

CONFIG_FILE="${SCRIPT_DIR}/config.sh"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="/etc/restic/config.sh"
SNAPSHOT_ID=""

# Runtime state
RESTORE_DIR=""

# =============================================================================
# Logging
# =============================================================================

LOG_FILE="/tmp/restore-$(date '+%Y-%m-%d').log"

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
# Cleanup
# =============================================================================

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with code: $exit_code"
        if [[ -n "$RESTORE_DIR" && -d "$RESTORE_DIR" ]]; then
            log_warn "Restore directory preserved for inspection: $RESTORE_DIR"
        fi
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

Interactively restore files or databases from a restic repository.

OPTIONS:
    --config FILE       Path to config file (default: ${SCRIPT_DIR}/config.sh)
    --snapshot ID       Use a specific snapshot ID (skips the selection prompt)
    -h, --help          Show this help message

EXAMPLE:
    sudo $SCRIPT_NAME
    sudo $SCRIPT_NAME --snapshot abc12345
    sudo $SCRIPT_NAME --config /etc/restic/config.sh
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

    export RESTIC_PASSWORD_FILE
    export RESTIC_REPOSITORY
    export RESTIC_CACHE_DIR

    LOG_FILE="${LOG_DIR}/restore-$(date '+%Y-%m-%d').log"
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
}

# =============================================================================
# Snapshot selection
# =============================================================================

select_snapshot() {
    if [[ -n "$SNAPSHOT_ID" ]]; then
        log_info "Using snapshot: $SNAPSHOT_ID"
        return 0
    fi

    echo ""
    echo "Available snapshots:"
    echo "--------------------"
    restic snapshots
    echo ""
    read -r -p "Enter snapshot ID (or 'latest'): " SNAPSHOT_ID

    if [[ -z "$SNAPSHOT_ID" ]]; then
        log_error "No snapshot ID provided."
        exit 1
    fi
}

# =============================================================================
# Restore helpers
# =============================================================================

create_restore_dir() {
    RESTORE_DIR="$(mktemp -d /tmp/restic-restore-XXXXXX)"
    chmod 700 "$RESTORE_DIR"
    log_info "Restore directory: $RESTORE_DIR"
}

restore_path() {
    local include_path="$1"
    log_info "Restoring: $include_path"
    restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --include "$include_path"
    log_info "Restored to: ${RESTORE_DIR}${include_path}"
}

restore_all() {
    log_info "Restoring full snapshot..."
    restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR"
    log_info "Full restore completed to: $RESTORE_DIR"
}

# =============================================================================
# Database restore helpers
# =============================================================================

list_sql_dumps() {
    local dump_base_dir="$1"
    find "$dump_base_dir" -name "*.sql" -type f 2>/dev/null | sort
}

import_mysql_dump() {
    local dump_file="$1"
    local target_db="$2"

    if ! command -v mysql &>/dev/null; then
        log_error "mysql client not found — cannot import dump."
        return 1
    fi

    log_info "Importing $dump_file into database: $target_db"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${target_db}\`;"
    mysql "$target_db" <"$dump_file"
    log_info "Import complete: $target_db"
}

restore_mysql_dumps() {
    # Extract DB dumps from the snapshot first
    # Attempt common dump directory patterns used by backup.sh
    local found_dir=""
    local candidate
    for candidate in "${RESTORE_DIR}/tmp/restic-db-dump"* "${RESTORE_DIR}/tmp/mysql_backup"; do
        if [[ -d "$candidate" ]]; then
            found_dir="$candidate"
            break
        fi
    done

    if [[ -z "$found_dir" ]]; then
        # Try to restore DB dumps by searching for the path inside the snapshot
        log_info "Looking for DB dumps in snapshot..."
        # Restore the entire /tmp subtree to find the dump directories
        restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --include "/tmp/restic-db-dump*" || true
        restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --include "/tmp/mysql_backup" || true

        for candidate in "${RESTORE_DIR}/tmp/restic-db-dump"* "${RESTORE_DIR}/tmp/mysql_backup"; do
            if [[ -d "$candidate" ]]; then
                found_dir="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$found_dir" ]]; then
        log_warn "No database dump directory found in this snapshot."
        return 1
    fi

    local dump_files
    mapfile -t dump_files < <(list_sql_dumps "$found_dir")

    if [[ ${#dump_files[@]} -eq 0 ]]; then
        log_warn "No .sql files found in: $found_dir"
        return 1
    fi

    echo ""
    echo "Available database dumps:"
    local i=1
    local dump
    for dump in "${dump_files[@]}"; do
        echo "  $i) $(basename "$dump")"
        ((i++))
    done
    echo "  a) All databases"
    echo ""

    read -r -p "Select dump(s) to restore [1-$((i-1)), a, or Enter to cancel]: " selection

    [[ -z "$selection" ]] && { log_info "Database restore cancelled."; return 0; }

    if [[ "$selection" == "a" ]]; then
        local f
        for f in "${dump_files[@]}"; do
            local db_name
            db_name="$(basename "$f" .sql)"
            # Strip container prefix if present (e.g. "mycontainer_mydb" → "mydb")
            db_name="${db_name##*_}"
            read -r -p "Restore '$(basename "$f")' into database '$db_name'? [y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && import_mysql_dump "$f" "$db_name"
        done
    else
        local idx
        for idx in $selection; do
            local dump_file="${dump_files[$((idx - 1))]}"
            local db_name
            db_name="$(basename "$dump_file" .sql)"
            db_name="${db_name##*_}"
            read -r -p "Restore into database '$db_name'? (or enter a different name): " target_db
            target_db="${target_db:-$db_name}"
            import_mysql_dump "$dump_file" "$target_db"
        done
    fi
}

# =============================================================================
# Interactive menu
# =============================================================================

show_restore_menu() {
    echo ""
    echo "What do you want to restore?"
    echo "----------------------------"
    echo "  1) Full backup (all paths)"
    echo "  2) Web files (/var/www)"
    echo "  3) Configuration (/etc)"
    echo "  4) Home directories (/home)"
    echo "  5) Database dumps (SQL files from backup)"
    echo "  6) SSL certificates (/etc/letsencrypt)"
    echo "  7) Custom path"
    echo "  q) Quit"
    echo ""
    read -r -p "Choice [1-7, q]: " choice

    case "$choice" in
        1)
            restore_all
            ;;
        2)
            restore_path "/var/www"
            ;;
        3)
            restore_path "/etc"
            ;;
        4)
            restore_path "/home"
            ;;
        5)
            # Dumps may already be in RESTORE_DIR from a previous restore step,
            # or we need to pull them from the snapshot.
            restore_mysql_dumps
            ;;
        6)
            restore_path "/etc/letsencrypt"
            echo ""
            echo "SSL certificates restored to: ${RESTORE_DIR}/etc/letsencrypt"
            echo ""
            echo "To apply them:"
            echo "  1. systemctl stop certbot.timer"
            echo "  2. cp -r ${RESTORE_DIR}/etc/letsencrypt/* /etc/letsencrypt/"
            echo "  3. chown -R root:root /etc/letsencrypt"
            echo "  4. systemctl start certbot.timer"
            echo "  5. systemctl reload apache2   # or nginx"
            ;;
        7)
            read -r -p "Enter path to restore: " custom_path
            if [[ -z "$custom_path" ]]; then
                log_error "No path provided."
                exit 1
            fi
            restore_path "$custom_path"
            ;;
        q | Q)
            log_info "Restore cancelled."
            rm -rf "$RESTORE_DIR"
            RESTORE_DIR=""
            exit 0
            ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --snapshot)
                SNAPSHOT_ID="$2"
                shift 2
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
    select_snapshot
    create_restore_dir
    show_restore_menu

    echo ""
    log_info "Restore complete. Files are in: $RESTORE_DIR"
    echo ""
    echo "Review the restored files before moving them into place."
    echo "When done, remove the restore directory:"
    echo "  rm -rf \"$RESTORE_DIR\""
}

main "$@"
