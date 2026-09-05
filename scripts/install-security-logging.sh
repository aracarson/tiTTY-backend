#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install-security-logging.sh" >&2
  exit 1
fi

dnf install -y audit
systemctl enable --now auditd

mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald

cat <<'INFO'
Security logging is enabled.

Review recent system and service activity with:
  journalctl --since '24 hours ago'
  ausearch -m USER_CMD,USER_START,USER_END --start recent

Audit logs can include sensitive command arguments. Restrict access and retain them according to your operational policy.
INFO
