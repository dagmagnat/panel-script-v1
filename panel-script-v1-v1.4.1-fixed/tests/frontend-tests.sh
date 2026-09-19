#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PSV1_SOURCE_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"
trap - ERR

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
CONF="$TEST_TMP/cdn-origin.conf"

fail(){ echo "[FAIL] $*" >&2; exit 1; }
pass(){ echo "[ OK ] $*"; }

cat > "$CONF" <<'NGINX'
upstream xray_xhttp { server 127.0.0.1:7443; keepalive 128; }
server {
    listen 80 default_server;
    server_name _;
    location /uploadfiles/ {
        proxy_pass http://xray_xhttp;
        proxy_buffering off;
    }
    location / { root /var/www/cdn-placeholder; index index.html; try_files $uri $uri/ /index.html; }
}
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /old/cert;
    ssl_certificate_key /old/key;
    location /uploadfiles/ {
        proxy_pass http://xray_xhttp;
        proxy_buffering off;
    }
    location / { root /var/www/cdn-placeholder; index index.html; try_files $uri $uri/ /index.html; }
}
server {
    listen 443 ssl;
    server_name panel.example.com;
    location / { proxy_pass http://127.0.0.1:3000; }
}
NGINX

cover_patch_nginx_config "$CONF" sftpgo
[[ "$(grep -c 'panel-script-v1 cover-service begin' "$CONF")" == 2 ]] \
  || fail "both CDN fallback locations were not managed"
[[ "$(grep -c 'proxy_pass http://127.0.0.1:18080;' "$CONF")" == 2 ]] \
  || fail "SFTPGo backend was not installed in both origin servers"
[[ "$(grep -c 'proxy_pass http://xray_xhttp;' "$CONF")" == 2 ]] \
  || fail "XHTTP proxy locations changed"
grep -Fq 'location / { proxy_pass http://127.0.0.1:3000; }' "$CONF" \
  || fail "panel vhost changed"
pass "SFTPGo replaces only CDN fallback locations"

cp "$CONF" "$CONF.once"
cover_patch_nginx_config "$CONF" sftpgo
cmp -s "$CONF" "$CONF.once" || fail "SFTPGo patch is not idempotent"
pass "SFTPGo patch is idempotent"

cover_patch_nginx_config "$CONF" placeholder
[[ "$(grep -c 'root /var/www/cdn-placeholder' "$CONF")" == 2 ]] \
  || fail "placeholder fallback was not restored"
[[ "$(grep -c 'proxy_pass http://xray_xhttp;' "$CONF")" == 2 ]] \
  || fail "XHTTP proxy changed while restoring placeholder"
pass "placeholder restore preserves XHTTP locations"

printf 'server { listen 443 ssl; location / { return 404; } }\n' > "$CONF"
cp "$CONF" "$CONF.before"
if cover_patch_nginx_config "$CONF" sftpgo 2>/dev/null; then
  fail "unknown nginx config must be rejected"
fi
cmp -s "$CONF" "$CONF.before" || fail "rejected nginx config was modified"
pass "unknown nginx config is rejected without changes"

RELAY_CONF="$TEST_TMP/relay-origin.conf"
cat > "$RELAY_CONF" <<'NGINX'
upstream xray_xhttp { server 127.0.0.1:4443; keepalive 128; }
server {
    listen 443 ssl default_server;
    location /uploadfiles/ { proxy_pass http://xray_xhttp; }
}
NGINX
relay_patch_nginx_upstream "$RELAY_CONF" 7443
grep -Fq 'upstream xray_xhttp { server 127.0.0.1:7443;' "$RELAY_CONF" \
  || fail "relay upstream was not switched to cascade port 7443"
[[ "$(grep -c '127.0.0.1:7443' "$RELAY_CONF")" == 1 ]] \
  || fail "unexpected number of cascade upstreams"
pass "relay nginx upstream switches from base :4443 to cascade :7443"

cat > "$RELAY_CONF" <<'NGINX'
upstream xray_xhttp { server 127.0.0.1:4443; }
upstream xray_xhttp { server 127.0.0.1:5555; }
NGINX
cp "$RELAY_CONF" "$RELAY_CONF.before"
if relay_patch_nginx_upstream "$RELAY_CONF" 7443 2>/dev/null; then
  fail "ambiguous relay upstream config must be rejected"
fi
cmp -s "$RELAY_CONF" "$RELAY_CONF.before" \
  || fail "rejected ambiguous relay config was modified"
pass "ambiguous relay upstream is rejected without changes"

echo "All frontend tests passed."
