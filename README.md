# restic-backup-suite

Automated backup and interactive restore scripts for Linux servers using [restic](https://restic.net/).

Supports SFTP remotes (e.g. Hetzner Storage Box), local paths, S3, and any other restic backend. Includes optional Docker database dumps (MariaDB/MySQL and PostgreSQL) and optional service stop/start around the backup window.

## Features

- Full restic backup with configurable paths, excludes, and retention policy
- Automatic Docker MariaDB/MySQL and PostgreSQL container dumps before backup
- Optional native (non-Docker) MySQL/MariaDB dump
- Optional stop/start of systemd services around the backup window
- Interactive restore menu — full backup, individual paths, databases, SSL certs, or custom path
- Structured logging with timestamps
- Strict mode (`set -euo pipefail`) throughout
- ShellCheck clean (CI enforced)

## Requirements

- Bash 4.4+
- [restic](https://restic.net/) in `PATH`
- Root access (scripts require `sudo`)
- `sftp` (only for SFTP remote backends)
- `docker` (only for Docker DB dumps)
- `mysqldump` / `mysql` (only for native MySQL dumps / restore)

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/restic-backup-suite.git
cd restic-backup-suite
```

### 2. Create your configuration

```bash
cp config.example.sh config.sh
chmod 600 config.sh   # Only root should read this
```

Edit `config.sh` and fill in all values. The file is well-commented — every option is explained. `config.sh` is gitignored and will never be committed.

### 3. Create a restic password file

```bash
echo "your-strong-passphrase" > /etc/restic/password.txt
chmod 400 /etc/restic/password.txt
```

Point `RESTIC_PASSWORD_FILE` in `config.sh` to this file.

### 4. Set up SSH (SFTP backend only)

Generate a dedicated key pair for the backup connection:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_backup -N ""
```

Copy the public key to your remote server / storage box, then set `SSH_KEY_FILE` in `config.sh`.

On first run, `backup.sh` will write the SSH config fragment and you can verify the connection with:

```bash
sftp myhost
```

### 5. Run a first backup

```bash
sudo ./backup.sh --dry-run   # Preview what would be backed up
sudo ./backup.sh             # Run the actual backup
```

On the first run the restic repository is initialized automatically if it does not exist yet.

### 6. Automate via cron

```
# /etc/cron.d/restic-backup
0 3 * * * root /path/to/restic-backup-suite/backup.sh >> /var/log/restic/cron.log 2>&1
```

## Configuration reference

All options live in `config.sh` (see `config.example.sh` for the full annotated template):

| Variable | Description | Default |
|---|---|---|
| `RESTIC_PASSWORD_FILE` | Path to the password file | `/etc/restic/password.txt` |
| `RESTIC_REPOSITORY` | Repository URL | — |
| `RESTIC_CACHE_DIR` | Local cache directory | `~/.cache/restic` |
| `GOMAXPROCS` | CPU cores for restic | `2` |
| `SSH_HOST` | SSH alias (SFTP only) | — |
| `SSH_HOSTNAME` | Real remote hostname | — |
| `SSH_PORT` | SSH port | `22` |
| `SSH_USER` | SSH username | — |
| `SSH_KEY_FILE` | SSH private key path | — |
| `LOG_DIR` | Log file directory | `/var/log/restic` |
| `BACKUP_PATHS` | Array of paths to back up | — |
| `BACKUP_EXCLUDES` | Array of exclude patterns | — |
| `RETENTION_KEEP_DAILY` | Daily snapshots to keep | `7` |
| `RETENTION_KEEP_WEEKLY` | Weekly snapshots to keep | `4` |
| `RETENTION_KEEP_MONTHLY` | Monthly snapshots to keep | `6` |
| `REPO_CHECK_SUBSET` | Fraction of data to verify | `5%` |
| `MYSQL_BACKUP_ENABLED` | Enable native MySQL dump | `false` |
| `DOCKER_MARIADB_CONTAINERS` | MariaDB containers to dump | `()` |
| `DOCKER_POSTGRES_CONTAINERS` | PostgreSQL containers to dump | `()` |
| `SERVICES_TO_STOP` | Systemd services to pause | `()` |

## Usage

### backup.sh

```
Usage: sudo ./backup.sh [OPTIONS]

OPTIONS:
    --config FILE   Path to config file (default: ./config.sh)
    --dry-run       Show what would be backed up without running restic
    -h, --help      Show this help message
```

### restore.sh

```
Usage: sudo ./restore.sh [OPTIONS]

OPTIONS:
    --config FILE       Path to config file (default: ./config.sh)
    --snapshot ID       Use a specific snapshot ID (skips the selection prompt)
    -h, --help          Show this help message
```

The restore script presents an interactive menu:

```
What do you want to restore?
----------------------------
  1) Full backup (all paths)
  2) Web files (/var/www)
  3) Configuration (/etc)
  4) Home directories (/home)
  5) Database dumps (SQL files from backup)
  6) SSL certificates (/etc/letsencrypt)
  7) Custom path
  q) Quit
```

Restored files are always written to a temporary directory first. You review them before moving anything into place.

## Security notes

- `config.sh` is gitignored — never commit it
- The password file should be `chmod 400` (readable only by root)
- SSH keys should be `chmod 600`
- The SSH config fragment written by `backup.sh` uses `IdentitiesOnly yes` and does **not** disable host key checking — set up your `known_hosts` properly on first connect

## License

MIT
