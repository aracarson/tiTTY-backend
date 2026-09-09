#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/update-geolite-db.sh" >&2
  exit 1
fi

CREDENTIALS_FILE="${MAXMIND_CREDENTIALS_FILE:-/etc/titty-backend/maxmind.env}"
DATABASE_DIR="${GEOIP_DATABASE_DIR:-/var/lib/GeoIP}"
DATABASE_PATH="${GEOIP_DATABASE_PATH:-${DATABASE_DIR}/GeoLite2-City.mmdb}"
DOWNLOAD_URL="https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz"
TEMP_DIR="$(mktemp -d)"
CURL_CONFIG="${TEMP_DIR}/curl.conf"
ARCHIVE_PATH="${TEMP_DIR}/GeoLite2-City.tar.gz"

cleanup() {
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

if [[ ! -r "${CREDENTIALS_FILE}" ]]; then
  echo "Credentials file is missing or unreadable: ${CREDENTIALS_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CREDENTIALS_FILE}"

if [[ -z "${MAXMIND_ACCOUNT_ID:-}" || -z "${MAXMIND_LICENSE_KEY:-}" ]]; then
  echo "MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY are required in ${CREDENTIALS_FILE}" >&2
  exit 1
fi

if [[ "$(stat -c '%a' "${CREDENTIALS_FILE}")" != "600" ]]; then
  echo "Credentials file must have mode 0600: ${CREDENTIALS_FILE}" >&2
  exit 1
fi

install -d -o root -g root -m 0750 "${DATABASE_DIR}"

# Keep the secret out of curl's process arguments and shell history.
printf 'url = "%s"\nuser = "%s:%s"\n' \
  "${DOWNLOAD_URL}" \
  "${MAXMIND_ACCOUNT_ID}" \
  "${MAXMIND_LICENSE_KEY}" > "${CURL_CONFIG}"
chmod 0600 "${CURL_CONFIG}"

curl --fail --silent --show-error --location --config "${CURL_CONFIG}" \
  --output "${ARCHIVE_PATH}"

tar -xzf "${ARCHIVE_PATH}" -C "${TEMP_DIR}"
NEW_DATABASE_PATH="$(find "${TEMP_DIR}" -type f -name 'GeoLite2-City.mmdb' -print -quit)"
if [[ -z "${NEW_DATABASE_PATH}" ]]; then
  echo "GeoLite2-City.mmdb was not found in the downloaded archive" >&2
  exit 1
fi

install -o root -g root -m 0640 "${NEW_DATABASE_PATH}" "${DATABASE_PATH}.new"
mv -f "${DATABASE_PATH}.new" "${DATABASE_PATH}"
echo "Installed ${DATABASE_PATH}"
