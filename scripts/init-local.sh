#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Create a local development environment safely

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
mkdir -p data
chmod 0700 data

if [[ ! -f .env ]]; then
  cp .env.example .env
  SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
  python3 - "${SECRET}" <<'PY'
from pathlib import Path
import sys
p = Path('.env')
s = p.read_text()
s = s.replace('replace-with-at-least-32-random-bytes', sys.argv[1])
s = s.replace('sqlite:///var/lib/titty-backend/identity.db?mode=rwc', 'sqlite://data/identity.db?mode=rwc')
s = s.replace('https://your-client-or-admin-origin.example', 'http://localhost:3000')
p.write_text(s)
PY
  chmod 0600 .env
fi

echo "Local environment created. Run: cargo run"
