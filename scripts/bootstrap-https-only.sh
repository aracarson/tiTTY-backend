#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Enable SSM administration when available
# [x] Apply the HTTPS-only host firewall
# [x] Avoid exposing SSH, HTTP or Axum publicly

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v dnf >/dev/null 2>&1; then
  dnf install -y firewalld amazon-ssm-agent
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y firewalld
fi

if systemctl list-unit-files | grep -q '^amazon-ssm-agent.service'; then
  systemctl enable --now amazon-ssm-agent
fi

"${SCRIPT_DIR}/configure-https-only-firewall.sh"
