# restic-backup-suite

Automated backup and interactive restore toolkit for Linux servers using [restic](https://restic.net/).

Supports SFTP, local, S3, B2, and all other restic backends. Includes Docker DB dumps (MariaDB/MySQL, PostgreSQL), optional native MySQL dumps, systemd service stop/start around the backup window, and a system-wide installer with shell aliases.

[![GitHub](https://img.shields.io/badge/GitHub-restic--backup--suite-blue?logo=github)](https://github.com/markus-michalski/restic-backup-suite)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Bash-4.4%2B-4EAA25.svg?logo=gnubash)](https://www.gnu.org/software/bash/)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen.svg)](https://www.shellcheck.net/)

## Documentation

Full documentation including setup guide, configuration reference, and troubleshooting:

- [Deutsch](https://faq.markus-michalski.net/de/bash-scripts/restic-backup-suite)
- [English](https://faq.markus-michalski.net/en/bash-scripts/restic-backup-suite)

## Quick Start

```bash
git clone https://github.com/markus-michalski/restic-backup-suite.git
cd restic-backup-suite
sudo ./install.sh
sudo nano /etc/restic/config.sh
sudo restic-backup --dry-run
```

## License

MIT
