#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Install Caddy
# [x] Install and validate the HTTPS-only reverse proxy

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

DOMAIN="${1:?Usage: sudo ./scripts/install-caddy.sh iden.titty.app}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v caddy >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y 'dnf-command(copr)'
    dnf copr enable -y @caddy/caddy
    dnf install -y caddy
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
  else
    echo "Unsupported Linux distribution" >&2
    exit 1
  fi
fi

sed "s/identity\\.example\\.com/${DOMAIN}/g" \
  "${REPO_DIR}/config/Caddyfile.example" > /etc/caddy/Caddyfile
chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl restart caddy

echo "HTTPS-only endpoint: https://${DOMAIN}/graphql"
