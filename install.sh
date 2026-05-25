#!/usr/bin/env bash
#
# install.sh — Install restic-backup-suite system-wide
#
# What this does:
#   1. Checks for restic (and offers install instructions if missing)
#   2. Creates /etc/restic/ and copies config.example.sh there
#   3. Creates /var/log/restic/
#   4. Installs symlinks: /usr/local/bin/restic-backup + restic-restore
#   5. Writes /etc/profile.d/restic-aliases.sh with convenience aliases
#   6. Optionally installs a daily cron job
#
# Usage:
#   sudo ./install.sh [--cron] [--uninstall]
#

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly CONFIG_DIR="/etc/restic"
readonly LOG_DIR="/var/log/restic"
readonly BIN_DIR="/usr/local/bin"
readonly PROFILE_SCRIPT="/etc/profile.d/restic-aliases.sh"
readonly CRON_FILE="/etc/cron.d/restic-backup"

INSTALL_CRON=false
UNINSTALL=false

# =============================================================================
# Helpers
# =============================================================================

info()    { echo "  [+] $*"; }
success() { echo "  [✓] $*"; }
warn()    { echo "  [!] $*" >&2; }
error()   { echo "  [✗] $*" >&2; }

check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        error "This script must be run as root."
        exit 1
    fi
}

usage() {
    cat <<EOF
Usage: sudo ./install.sh [OPTIONS]

OPTIONS:
    --cron        Also install a daily cron job (runs backup.sh at 03:00)
    --uninstall   Remove everything installed by this script
    -h, --help    Show this help message
EOF
}

# =============================================================================
# Dependency check
# =============================================================================

check_restic() {
    if command -v restic &>/dev/null; then
        success "restic $(restic version | head -1) found."
        return 0
    fi

    warn "restic is not installed."
    echo ""
    echo "  Install options:"
    echo ""
    echo "  Debian/Ubuntu (via apt):"
    echo "    apt install restic"
    echo ""
    echo "  Any Linux (latest release from GitHub):"
    echo "    curl -fsSL https://raw.githubusercontent.com/restic/restic/master/cmd/restic/go_flags.go"
    echo "    # or download the binary directly:"
    echo "    curl -L https://github.com/restic/restic/releases/latest/download/restic_linux_amd64.bz2 | bzcat > /usr/local/bin/restic"
    echo "    chmod +x /usr/local/bin/restic"
    echo ""
    read -r -p "  Continue installation without restic? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
}

# =============================================================================
# Install
# =============================================================================

install_config() {
    info "Creating config directory: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    if [[ -f "${CONFIG_DIR}/config.sh" ]]; then
        warn "Config already exists: ${CONFIG_DIR}/config.sh — not overwriting."
    else
        cp "${SCRIPT_DIR}/config.example.sh" "${CONFIG_DIR}/config.sh"
        chmod 600 "${CONFIG_DIR}/config.sh"
        success "Config template installed: ${CONFIG_DIR}/config.sh"
        echo ""
        echo "  --> Edit ${CONFIG_DIR}/config.sh and fill in your values."
        echo ""
    fi

    # Always keep the example up to date
    cp "${SCRIPT_DIR}/config.example.sh" "${CONFIG_DIR}/config.example.sh"
    chmod 640 "${CONFIG_DIR}/config.example.sh"
}

install_log_dir() {
    info "Creating log directory: $LOG_DIR"
    mkdir -p "$LOG_DIR"
    chmod 750 "$LOG_DIR"
    success "Log directory ready: $LOG_DIR"
}

install_symlinks() {
    info "Installing symlinks in $BIN_DIR"

    local script target
    for script in backup restore; do
        target="${BIN_DIR}/restic-${script}"
        if [[ -L "$target" ]]; then
            rm "$target"
        fi
        ln -s "${SCRIPT_DIR}/${script}.sh" "$target"
        chmod +x "${SCRIPT_DIR}/${script}.sh"
        success "restic-${script} -> ${SCRIPT_DIR}/${script}.sh"
    done
}

install_aliases() {
    info "Installing shell aliases: $PROFILE_SCRIPT"

    cat >"$PROFILE_SCRIPT" <<'ALIASES'
# restic-backup-suite convenience aliases
# Loaded automatically for all login shells via /etc/profile.d/

# Load restic environment from the system config
_restic_load_env() {
    local cfg="/etc/restic/config.sh"
    if [[ -f "$cfg" ]]; then
        # shellcheck source=/dev/null
        source "$cfg"
        export RESTIC_PASSWORD_FILE RESTIC_REPOSITORY RESTIC_CACHE_DIR GOMAXPROCS
    else
        echo "restic config not found: $cfg" >&2
        return 1
    fi
}

# List all snapshots
alias restic-snapshots='_restic_load_env && restic snapshots'

# Show repository statistics
alias restic-stats='_restic_load_env && restic stats --mode restore-size'

# Check repository integrity (5% data sample)
alias restic-check='_restic_load_env && restic check --read-data-subset=5%'

# List files in the latest snapshot
alias restic-ls='_restic_load_env && restic ls latest'

# Mount repository as a filesystem (requires FUSE)
# Usage: restic-mount /mnt/restic
alias restic-mount='_restic_load_env && restic mount'

# Unlock a stale lock (use after an interrupted backup)
alias restic-unlock='_restic_load_env && restic unlock'

# Show raw repository size on disk
alias restic-rawstats='_restic_load_env && restic stats --mode raw-data latest'
ALIASES

    chmod 644 "$PROFILE_SCRIPT"
    success "Aliases installed. Reload with: source $PROFILE_SCRIPT"
    echo ""
    echo "  Available after next login (or source now):"
    echo "    restic-snapshots   — list all snapshots"
    echo "    restic-stats       — repository size and dedup stats"
    echo "    restic-check       — integrity check (5% sample)"
    echo "    restic-ls          — list files in latest snapshot"
    echo "    restic-mount       — mount repo via FUSE"
    echo "    restic-unlock      — remove stale lock"
    echo "    restic-rawstats    — raw on-disk size"
    echo ""
}

install_cron() {
    info "Installing cron job: $CRON_FILE"

    cat >"$CRON_FILE" <<EOF
# restic-backup-suite — daily backup at 03:00
# To disable: rm $CRON_FILE
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * * root ${BIN_DIR}/restic-backup >> ${LOG_DIR}/cron.log 2>&1
EOF

    chmod 644 "$CRON_FILE"
    success "Cron job installed: runs daily at 03:00"
    warn "Make sure ${CONFIG_DIR}/config.sh is configured before the first run!"
}

# =============================================================================
# Uninstall
# =============================================================================

uninstall() {
    echo ""
    echo "Removing restic-backup-suite system files..."
    echo ""
    warn "This does NOT remove your restic repository or password file."
    echo ""

    local script
    for script in backup restore; do
        local target="${BIN_DIR}/restic-${script}"
        if [[ -L "$target" ]]; then
            rm "$target"
            success "Removed: $target"
        fi
    done

    if [[ -f "$PROFILE_SCRIPT" ]]; then
        rm "$PROFILE_SCRIPT"
        success "Removed: $PROFILE_SCRIPT"
    fi

    if [[ -f "$CRON_FILE" ]]; then
        rm "$CRON_FILE"
        success "Removed: $CRON_FILE"
    fi

    echo ""
    warn "Config and logs were NOT removed:"
    warn "  $CONFIG_DIR"
    warn "  $LOG_DIR"
    echo ""
    read -r -p "  Remove config directory ${CONFIG_DIR}? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        rm -rf "$CONFIG_DIR"
        success "Removed: $CONFIG_DIR"
    fi

    echo ""
    success "Uninstall complete."
}

# =============================================================================
# Main
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)
                INSTALL_CRON=true
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    check_root

    if [[ "$UNINSTALL" == "true" ]]; then
        uninstall
        exit 0
    fi

    echo ""
    echo "Installing restic-backup-suite..."
    echo ""

    check_restic
    install_config
    install_log_dir
    install_symlinks
    install_aliases

    if [[ "$INSTALL_CRON" == "true" ]]; then
        install_cron
    fi

    echo ""
    echo "============================================"
    success "Installation complete."
    echo "============================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Edit your config:"
    echo "       nano ${CONFIG_DIR}/config.sh"
    echo ""
    echo "  2. Test the connection (SFTP):"
    echo "       sftp \$SSH_HOST"
    echo ""
    echo "  3. Dry-run to verify paths:"
    echo "       restic-backup --dry-run"
    echo ""
    echo "  4. Run first backup:"
    echo "       restic-backup"
    echo ""
    if [[ "$INSTALL_CRON" == "false" ]]; then
        echo "  5. Set up cron (optional):"
        echo "       sudo ./install.sh --cron"
        echo ""
    fi
    echo "  Reload aliases now (or just open a new shell):"
    echo "       source $PROFILE_SCRIPT"
    echo ""
}

main "$@"
