#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PSV1_SOURCE_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"
trap - ERR

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail(){ echo "[FAIL] $*" >&2; exit 1; }
pass(){ echo "[ OK ] $*"; }

CONF="$TEST_TMP/remnawave-panel.conf"
cat > "$CONF" <<'NGINX'
server {
    listen 80;
    server_name pnl.amoredd.ru;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
}
server {
    listen 443 ssl http2;
    server_name pnl.amoredd.ru _;
    ssl_certificate /old/server.crt;
    ssl_certificate_key /old/server.key;
    location = /static/getFile/video/segment.ts {
        proxy_pass http://127.0.0.1:7443;
    }
    location / { proxy_pass http://127.0.0.1:3000; }
}
NGINX

panel_cert_patch_nginx_config "$CONF" pnl.amoredd.ru \
  certs/panel/fullchain.pem certs/panel/privkey.pem
grep -Fq 'ssl_certificate certs/panel/fullchain.pem;' "$CONF" \
  || fail "certificate path was not replaced"
grep -Fq 'ssl_certificate_key certs/panel/privkey.pem;' "$CONF" \
  || fail "key path was not replaced"
grep -Fq 'proxy_pass http://127.0.0.1:7443;' "$CONF" \
  || fail "cascade location was changed"
grep -Fq 'proxy_pass http://127.0.0.1:3000;' "$CONF" \
  || fail "panel upstream was changed"
pass "only certificate pair in the panel vhost is replaced"

cp "$CONF" "$CONF.before"
if panel_cert_patch_nginx_config "$CONF" other.example.com new/cert new/key 2>/dev/null; then
  fail "missing vhost must be rejected"
fi
cmp -s "$CONF" "$CONF.before" || fail "rejected config was modified"
pass "missing panel vhost is rejected without changes"

cat >> "$CONF" <<'NGINX'
server {
    listen 443 ssl;
    server_name pnl.amoredd.ru;
    ssl_certificate /second/cert;
    ssl_certificate_key /second/key;
}
NGINX
cp "$CONF" "$CONF.before"
if panel_cert_patch_nginx_config "$CONF" pnl.amoredd.ru new/cert new/key 2>/dev/null; then
  fail "ambiguous vhost must be rejected"
fi
cmp -s "$CONF" "$CONF.before" || fail "ambiguous config was modified"
pass "ambiguous HTTPS vhosts are rejected without changes"

echo "All panel certificate tests passed."
