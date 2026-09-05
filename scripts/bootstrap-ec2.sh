#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Prepare an Amazon Linux 2023 ARM instance
# [x] Create least-privilege service user and directories
# [x] Install build, SQLite and backup dependencies

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/bootstrap-ec2.sh" >&2
  exit 1
fi

SERVICE_USER="titty-backend"
INSTALL_DIR="/opt/titty-backend"
DATA_DIR="/var/lib/titty-backend"
CONFIG_DIR="/etc/titty-backend"

if command -v dnf >/dev/null 2>&1; then
  dnf update -y
  dnf install -y gcc gcc-c++ make pkgconfig sqlite sqlite-devel openssl-devel git tar gzip awscli2
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential pkg-config sqlite3 libsqlite3-dev libssl-dev git curl awscli
else
  echo "Unsupported Linux distribution" >&2
  exit 1
fi

if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${DATA_DIR}" --shell /sbin/nologin "${SERVICE_USER}"
fi

install -d -o root -g root -m 0755 "${INSTALL_DIR}" "${INSTALL_DIR}/bin"
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 "${DATA_DIR}"
install -d -o root -g "${SERVICE_USER}" -m 0750 "${CONFIG_DIR}"
install -d -o root -g root -m 0755 /var/log/titty-backend

if ! command -v cargo >/dev/null 2>&1; then
  export RUSTUP_HOME=/usr/local/rustup
  export CARGO_HOME=/usr/local/cargo
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  ln -sf /usr/local/cargo/bin/rustc /usr/local/bin/rustc
  ln -sf /usr/local/cargo/bin/cargo /usr/local/bin/cargo
fi

echo "EC2 host prepared. Copy the repository and run scripts/deploy.sh."
