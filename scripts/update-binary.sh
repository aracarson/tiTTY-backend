#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/update-binary.sh /path/to/titty-backend" >&2
  exit 1
fi

SOURCE_BINARY="${1:-}"
TARGET_BINARY="/opt/titty-backend/bin/titty-backend"
INSTALL_DIR="/opt/titty-backend/bin"
SERVICE_NAME="titty-backend.service"
HEALTH_URL="http://127.0.0.1:8080/healthz"
BACKUP_BINARY="${TARGET_BINARY}.$(date -u +%Y%m%dT%H%M%SZ).bak"
TEMP_BINARY="${TARGET_BINARY}.new.$$"

if [[ -z "${SOURCE_BINARY}" || ! -f "${SOURCE_BINARY}" ]]; then
  echo "Usage: sudo bash $0 /path/to/titty-backend" >&2
  exit 1
fi

if [[ ! -r "${SOURCE_BINARY}" ]]; then
  echo "Source binary is not readable: ${SOURCE_BINARY}" >&2
  exit 1
fi

if [[ ! -x "${TARGET_BINARY}" ]]; then
  echo "Installed binary is missing or not executable: ${TARGET_BINARY}" >&2
  exit 1
fi

install -d -o root -g root -m 0755 "${INSTALL_DIR}"

if [[ -f "${TARGET_BINARY}" ]]; then
  install -o root -g root -m 0755 "${TARGET_BINARY}" "${BACKUP_BINARY}"
  echo "Saved rollback binary: ${BACKUP_BINARY}"
fi

cleanup() {
  rm -f "${TEMP_BINARY}"
}
trap cleanup EXIT

install -o root -g root -m 0755 "${SOURCE_BINARY}" "${TEMP_BINARY}"
mv -f "${TEMP_BINARY}" "${TARGET_BINARY}"

if ! systemctl restart "${SERVICE_NAME}"; then
  echo "Service restart failed; restoring the previous binary." >&2
  if [[ -f "${BACKUP_BINARY}" ]]; then
    install -o root -g root -m 0755 "${BACKUP_BINARY}" "${TARGET_BINARY}"
    systemctl restart "${SERVICE_NAME}" || true
  fi
  exit 1
fi

if ! systemctl is-active --quiet "${SERVICE_NAME}" || ! curl --fail --silent --show-error "${HEALTH_URL}" >/dev/null; then
  echo "Service health check failed; restoring the previous binary." >&2
  if [[ -f "${BACKUP_BINARY}" ]]; then
    install -o root -g root -m 0755 "${BACKUP_BINARY}" "${TARGET_BINARY}"
    systemctl restart "${SERVICE_NAME}" || true
  fi
  exit 1
fi

echo "Updated ${TARGET_BINARY} and verified ${SERVICE_NAME}."
systemctl --no-pager --full status "${SERVICE_NAME}"
