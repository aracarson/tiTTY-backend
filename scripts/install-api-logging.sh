#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install-api-logging.sh" >&2
  exit 1
fi

LOG_DIR="${TITTY_API_LOG_DIR:-/var/log/titty-backend}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d -o titty-backend -g titty-backend -m 0750 "${LOG_DIR}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/cull-api-logs.sh" /opt/titty-backend/bin/cull-api-logs.sh
install -o root -g root -m 0644 "${SCRIPT_DIR}/titty-backend-api-log-cull.service" /etc/systemd/system/
install -o root -g root -m 0644 "${SCRIPT_DIR}/titty-backend-api-log-cull.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now titty-backend-api-log-cull.timer
systemctl restart titty-backend.service

cat <<INFO
Structured API logging is enabled.
Log directory: ${LOG_DIR}
Cleanup timer: titty-backend-api-log-cull.timer
INFO
