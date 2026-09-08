#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Download ARM64 Caddy with Route53 and Coraza plugins
# [x] Setup OWASP Coraza configuration in /etc/caddy/coraza/
# [x] Update /etc/caddy/Caddyfile with coraza_waf directive
# [x] Validate and restart Caddy service

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/setup-caddy-coraza.sh" >&2
  exit 1
fi

DOMAIN="${1:-iden.titty.app}"
CORAZA_DIR="/etc/caddy/coraza"

echo "1. Stopping Caddy service..."
systemctl stop caddy || true

echo "2. Downloading Caddy ARM64 binary with Route53 & Coraza plugins..."
curl -fL 'https://caddyserver.com/api/download?os=linux&arch=arm64&p=github.com/caddy-dns/route53&p=github.com/corazawaf/coraza-caddy/v2' \
  -o /tmp/caddy-coraza

install -o root -g root -m 0755 /tmp/caddy-coraza /usr/local/bin/caddy
rm -f /tmp/caddy-coraza

echo "Verifying loaded modules:"
/usr/local/bin/caddy list-modules | grep -E 'coraza|route53'

echo "3. Creating Coraza configuration..."
install -d -o root -g caddy -m 0750 "${CORAZA_DIR}"

# Download recommended Coraza base rules
curl -fsSL https://raw.githubusercontent.com/corazawaf/coraza/main/coraza.conf-recommended \
  -o "${CORAZA_DIR}/coraza.conf"

# Enable active blocking mode
sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' "${CORAZA_DIR}/coraza.conf"

# Ensure caddy user can read the rules
chown -R root:caddy "${CORAZA_DIR}"
chmod 0640 "${CORAZA_DIR}"/*.conf

echo "4. Updating /etc/caddy/Caddyfile..."
cat > /etc/caddy/Caddyfile <<EOF
{
    auto_https disable_redirects
    order coraza_waf first
}

https://${DOMAIN} {
    coraza_waf {
        include ${CORAZA_DIR}/coraza.conf
    }

    encode zstd gzip

    tls {
        dns route53
    }

    reverse_proxy 127.0.0.1:8080

    request_body {
        max_size 64KB
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        Content-Security-Policy "default-src 'none'; frame-ancestors 'none'"
        -Server
    }
}
EOF

chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

echo "5. Validating Caddyfile..."
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile

echo "6. Starting Caddy service..."
systemctl daemon-reload
systemctl restart caddy
systemctl --no-pager --full status caddy

echo "Coraza WAF setup complete for https://${DOMAIN}"
