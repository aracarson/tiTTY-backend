#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${TITTY_API_LOG_DIR:-/var/log/titty-backend}"
RETENTION_DAYS="${TITTY_API_LOG_RETENTION_DAYS:-14}"

ENV_FILE="/etc/titty-backend/titty-backend.env"
if [[ -r "${ENV_FILE}" ]]; then
  source "${ENV_FILE}"
  LOG_DIR="${TITTY_API_LOG_DIR:-/var/log/titty-backend}"
  RETENTION_DAYS="${TITTY_API_LOG_RETENTION_DAYS:-14}"
fi

if [[ ! -d "${LOG_DIR}" ]]; then
  exit 0
fi

find "${LOG_DIR}" \
  -maxdepth 1 \
  -type f \
  -name 'api-access.jsonl.*' \
  -mtime "+${RETENTION_DAYS}" \
  -delete
