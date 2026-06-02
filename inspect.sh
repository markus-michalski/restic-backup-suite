#!/usr/bin/env bash
#
# inspect.sh — Browse and inspect restic backup snapshots
#
# Usage:
#   sudo ./inspect.sh [--config /path/to/config.sh] [--snapshot SNAPSHOT_ID] [--help]
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
SNAPSHOT_ID="latest"

# =============================================================================
# Logging
# =============================================================================

LOG_FILE="/tmp/inspect-$(date '+%Y-%m-%d').log"

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

# shellcheck disable=SC2317  # Called via trap
cleanup() {
    local exit_code=$?
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

Browse and inspect restic backup snapshots without restoring files.

OPTIONS:
    --config FILE       Path to config file (default: ${SCRIPT_DIR}/config.sh)
    --snapshot ID       Snapshot to inspect (default: latest)
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

    LOG_FILE="${LOG_DIR}/inspect-$(date '+%Y-%m-%d').log"
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
    echo ""
    echo "Available snapshots:"
    echo "--------------------"
    restic snapshots
    echo ""
    read -r -p "Enter snapshot ID (or press Enter for 'latest'): " input_id

    if [[ -n "$input_id" ]]; then
        SNAPSHOT_ID="$input_id"
    fi

    log_info "Using snapshot: $SNAPSHOT_ID"
}

# =============================================================================
# Inspect actions
# =============================================================================

show_snapshot_details() {
    echo ""
    log_info "Details for snapshot: $SNAPSHOT_ID"
    echo ""
    restic snapshots "$SNAPSHOT_ID" --verbose
}

show_stats() {
    echo ""
    log_info "Statistics for snapshot: $SNAPSHOT_ID"
    echo ""
    restic stats "$SNAPSHOT_ID" --mode restore-size
}

list_files() {
    echo ""
    read -r -p "Path prefix to list (e.g. /var/www — or Enter for all): " path_prefix
    echo ""
    log_info "Listing files in snapshot $SNAPSHOT_ID..."

    local tmp_out
    tmp_out="$(mktemp)"

    if [[ -n "$path_prefix" ]]; then
        restic ls --long "$SNAPSHOT_ID" "$path_prefix" >"$tmp_out"
    else
        restic ls --long "$SNAPSHOT_ID" >"$tmp_out"
    fi

    local line_count
    line_count="$(wc -l <"$tmp_out")"
    echo "(${line_count} entries)"
    echo ""

    if [[ -t 1 && "$line_count" -gt 40 ]]; then
        less "$tmp_out"
    else
        cat "$tmp_out"
    fi

    rm -f "$tmp_out"
}

search_files() {
    echo ""
    read -r -p "Search substring (e.g. 'wp-config', 'nginx.conf', '.sql'): " pattern

    if [[ -z "$pattern" ]]; then
        log_error "No pattern provided."
        return 1
    fi

    echo ""
    log_info "Searching for '$pattern' in snapshot $SNAPSHOT_ID..."
    echo ""

    # Load all paths once; grep is then instant
    local tmp_out
    tmp_out="$(mktemp)"
    restic ls "$SNAPSHOT_ID" >"$tmp_out"

    local match_count
    match_count="$(grep -icF "$pattern" "$tmp_out" || true)"

    if [[ "$match_count" -eq 0 ]]; then
        echo "No results for: $pattern"
    else
        echo "${match_count} match(es):"
        echo ""
        grep -iF "$pattern" "$tmp_out"
    fi

    rm -f "$tmp_out"
}

show_diff() {
    echo ""
    echo "Current snapshot: $SNAPSHOT_ID"
    echo ""
    echo "Available snapshots:"
    echo "--------------------"
    restic snapshots
    echo ""
    read -r -p "Compare against snapshot ID: " other_id

    if [[ -z "$other_id" ]]; then
        log_error "No snapshot ID provided."
        return 1
    fi

    echo ""
    log_info "Diff: $SNAPSHOT_ID  vs  $other_id"
    echo ""
    restic diff "$SNAPSHOT_ID" "$other_id"
}

# =============================================================================
# Interactive menu
# =============================================================================

show_menu() {
    while true; do
        echo ""
        echo "Snapshot: $SNAPSHOT_ID"
        echo "================================"
        echo "  1) Show snapshot details"
        echo "  2) Show statistics (size)"
        echo "  3) List files (with optional path filter)"
        echo "  4) Search files by name/pattern"
        echo "  5) Diff against another snapshot"
        echo "  s) Select a different snapshot"
        echo "  q) Quit"
        echo ""
        read -r -p "Choice [1-5, s, q]: " choice

        case "$choice" in
            1) show_snapshot_details ;;
            2) show_stats ;;
            3) list_files ;;
            4) search_files ;;
            5) show_diff ;;
            s | S) select_snapshot ;;
            q | Q)
                log_info "Done."
                exit 0
                ;;
            *)
                log_warn "Invalid choice: $choice"
                ;;
        esac
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    local snapshot_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --snapshot)
                snapshot_arg="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                snapshot_arg="$1"
                shift
                ;;
        esac
    done

    check_root
    load_config
    check_dependencies

    if [[ -n "$snapshot_arg" ]]; then
        SNAPSHOT_ID="$snapshot_arg"
        log_info "Using snapshot: $SNAPSHOT_ID"
    else
        select_snapshot
    fi

    show_menu
}

main "$@"
