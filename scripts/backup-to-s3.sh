#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Create a consistent SQLite snapshot
# [x] Upload an encrypted backup to S3
# [x] Avoid copying a live WAL database file directly

DATABASE_PATH="${TITTY_DATABASE_PATH:-/var/lib/titty-backend/identity.db}"
BACKUP_DIR="${TITTY_BACKUP_DIR:-/var/lib/titty-backend/backups}"
S3_URI="${TITTY_BACKUP_S3_URI:?Set TITTY_BACKUP_S3_URI, for example s3://bucket/identity}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT="${BACKUP_DIR}/identity-${STAMP}.db"

install -d -m 0700 "${BACKUP_DIR}"
sqlite3 "${DATABASE_PATH}" ".timeout 5000" ".backup '${SNAPSHOT}'"
chmod 0600 "${SNAPSHOT}"

aws s3 cp "${SNAPSHOT}" "${S3_URI}/identity-${STAMP}.db"   --only-show-errors   --sse AES256

find "${BACKUP_DIR}" -type f -name 'identity-*.db' -mtime +2 -delete
