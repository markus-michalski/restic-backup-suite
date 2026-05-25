# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Nothing yet

### Changed
- Nothing yet

### Deprecated
- Nothing yet

### Removed
- Nothing yet

### Fixed
- Nothing yet

### Security
- Nothing yet

## [1.0.1] - 2026-05-25

### Fixed
- remove all invalid #{array[@]+"..."} substitutions
- remove remaining bad substitution in stop_services
- resolve symlink for SCRIPT_DIR, fix bad substitution in restart_services

## [1.0.0] - 2026-05-25

### Added
- `backup.sh` — automated restic backup with configurable paths, excludes, and retention policy
- `restore.sh` — interactive restore menu (full backup, individual paths, DB dumps, SSL certs, custom path)
- `install.sh` — system-wide installer with symlinks, shell aliases, and optional daily cron job
- `config.example.sh` — annotated configuration template
- Docker MariaDB/MySQL container dump support via `docker exec`
- Docker PostgreSQL container dump support via `docker exec`
- Native (non-Docker) MySQL/MariaDB dump support
- systemd service stop/start around backup window
- SSH config.d management (non-destructive, does not overwrite existing SSH config)
- Automatic restic repository initialization on first run
- Shell aliases via `/etc/profile.d/restic-aliases.sh`: `restic-snapshots`, `restic-stats`, `restic-check`, `restic-ls`, `restic-mount`, `restic-unlock`, `restic-rawstats`
- ShellCheck CI via GitHub Actions (syntax check + ShellCheck on all `.sh` files)

[Unreleased]: https://github.com/markus-michalski/restic-backup-suite/compare/v1.0.1...HEAD
[1.0.0]: https://github.com/markus-michalski/restic-backup-suite/releases/tag/v1.0.0
[1.0.1]: https://github.com/markus-michalski/restic-backup-suite/releases/tag/v1.0.1
