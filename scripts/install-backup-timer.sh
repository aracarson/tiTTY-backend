#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Install a daily systemd-backed S3 backup schedule

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

install -o root -g root -m 0755 scripts/backup-to-s3.sh /opt/titty-backend/bin/backup-to-s3.sh
install -o root -g root -m 0644 systemd/titty-backend-backup.service /etc/systemd/system/
install -o root -g root -m 0644 systemd/titty-backend-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now titty-backend-backup.timer
