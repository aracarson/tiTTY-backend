#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Build a release binary
# [x] Install files with restrictive ownership and permissions
# [x] Enable and restart systemd

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/deploy.sh" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_USER="titty-backend"
INSTALL_DIR="/opt/titty-backend"
CONFIG_DIR="/etc/titty-backend"
DATA_DIR="/var/lib/titty-backend"

cd "${REPO_DIR}"
if [[ -f Cargo.lock ]]; then
  cargo build --release --locked
else
  echo "WARNING: Cargo.lock is missing; generating it during the first build." >&2
  cargo build --release
fi

install -o root -g root -m 0755 target/release/titty-backend "${INSTALL_DIR}/bin/titty-backend"
install -o root -g root -m 0644 systemd/titty-backend.service /etc/systemd/system/titty-backend.service

if [[ ! -f "${CONFIG_DIR}/titty-backend.env" ]]; then
  install -o root -g "${SERVICE_USER}" -m 0640 .env.example "${CONFIG_DIR}/titty-backend.env"
  echo "Created ${CONFIG_DIR}/titty-backend.env. Set secrets and origin before starting." >&2
  exit 1
fi

chown -R "${SERVICE_USER}:${SERVICE_USER}" "${DATA_DIR}"
chmod 0700 "${DATA_DIR}"
chmod 0640 "${CONFIG_DIR}/titty-backend.env"

systemctl daemon-reload
systemctl enable titty-backend.service
systemctl restart titty-backend.service
systemctl --no-pager --full status titty-backend.service
