#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/generate-security-report.sh" >&2
  exit 1
fi

ENV_FILE="/etc/titty-backend/titty-backend.env"
if [[ -r "${ENV_FILE}" ]]; then
  # The deployment environment is root-owned and contains the backup URI.
  source "${ENV_FILE}"
fi

OUTPUT_DIR="${TITTY_SECURITY_REPORT_DIR:-/var/lib/titty-backend/security-reports}"
S3_ROOT="${TITTY_REPORTS_S3_URI:-s3://identitty/reports}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="${OUTPUT_DIR}/security-${STAMP}.txt"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for report upload" >&2
  exit 1
fi

install -d -m 0750 "${OUTPUT_DIR}"

{
  echo "tiTTY security report"
  echo "Generated: ${STAMP} UTC"
  echo
  echo "== Host =="
  hostnamectl 2>/dev/null || hostname
  echo
  uptime
  echo
  echo "== Failed systemd units =="
  systemctl --failed --no-legend --no-pager || true
  echo
  echo "== Critical service status =="
  systemctl --no-pager --full status titty-backend caddy amazon-ssm-agent 2>&1 || true
  echo
  echo "== SSM agent activity (last 24 hours) =="
  journalctl -u amazon-ssm-agent --since '24 hours ago' --no-pager 2>/dev/null || true
  echo
  echo "== SSH and authentication activity (last 24 hours) =="
  journalctl _COMM=sshd --since '24 hours ago' --no-pager 2>/dev/null || true
  journalctl SYSLOG_IDENTIFIER=sshd --since '24 hours ago' --no-pager 2>/dev/null || true
  journalctl -u systemd-logind --since '24 hours ago' --no-pager 2>/dev/null || true
  echo
  echo "== Privileged command audit (if auditd is installed) =="
  if command -v ausearch >/dev/null 2>&1; then
    ausearch -m USER_CMD,USER_START,USER_END --start recent 2>/dev/null || true
  else
    echo "auditd/ausearch is not installed; install audit for detailed command auditing."
  fi
  echo
  echo "== Package updates =="
  dnf history list 2>/dev/null | head -n 20 || true
  echo
  echo "== Listening sockets =="
  ss -ltnup 2>/dev/null || ss -ltn 2>/dev/null || true
  echo
  echo "== Disk and memory =="
  df -h
  free -h 2>/dev/null || true
} > "${REPORT}"

chmod 0600 "${REPORT}"

aws s3 cp "${REPORT}" "${S3_ROOT%/}/security-reports/" \
  --only-show-errors --sse AES256

find "${OUTPUT_DIR}" -type f -name 'security-*.txt' -mtime +14 -delete

echo "Generated security report: ${REPORT}"
echo "Uploaded security report: ${S3_ROOT%/}/security-reports/"
