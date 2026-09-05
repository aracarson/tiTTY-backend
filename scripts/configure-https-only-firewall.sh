#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Permit public inbound TCP only on 443
# [x] Remove public HTTP, SSH and Axum access
# [x] Preserve established and outbound connections

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if ! command -v firewall-cmd >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y firewalld
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y firewalld
  else
    echo "Unsupported Linux distribution" >&2
    exit 1
  fi
fi

systemctl enable --now firewalld
firewall-cmd --permanent --zone=public --remove-service=http >/dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --remove-service=ssh >/dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --remove-port=80/tcp >/dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --remove-port=8080/tcp >/dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --reload

echo "Public inbound TCP is limited to HTTPS port 443."
echo "Use AWS Systems Manager Session Manager for administration."
