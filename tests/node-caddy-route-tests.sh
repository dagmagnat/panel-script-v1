#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PSV1_SOURCE_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"
trap - ERR

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

cat > "$TEST_TMP/Caddyfile" <<'EOF'
file.example.ru {
    redir / /web/client/ 302
    reverse_proxy sftpgo:8080 {
        header_up X-Real-IP {remote_host}
    }
}
EOF

cat > "$TEST_TMP/docker" <<'EOF'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == inspect ]]; then
  [[ " $* " == *" --format "* ]] && echo 172.18.0.1
  exit 0
fi
if [[ "${1:-}" == exec ]]; then
  exit 0
fi
exit 1
EOF
chmod +x "$TEST_TMP/docker"
cat > "$TEST_TMP/nginx" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -t ]] && exit 0
exit 0
EOF
cat > "$TEST_TMP/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == reload && "${2:-}" == nginx ]] && exit 0
exit 0
EOF
chmod +x "$TEST_TMP/nginx" "$TEST_TMP/systemctl"
PATH="$TEST_TMP:$PATH"
export MSYS2_ARG_CONV_EXCL='/static/getFile/video/segment.ts'

run_node_caddy_route turboflare file.example.ru 7443 "$TEST_TMP/Caddyfile" >/dev/null
grep -Fq '@psv1_turboflare path /static/getFile/video/segment.ts' "$TEST_TMP/Caddyfile" || { cat "$TEST_TMP/Caddyfile"; exit 1; }
grep -Fq 'reverse_proxy @psv1_turboflare 172.18.0.1:7443' "$TEST_TMP/Caddyfile"
grep -Fq 'reverse_proxy sftpgo:8080' "$TEST_TMP/Caddyfile"

# Re-running updates the managed block instead of duplicating it.
run_node_caddy_route turboflare file.example.ru 7555 "$TEST_TMP/Caddyfile" >/dev/null
[[ $(grep -Fc 'PSV1-TURBOFLARE-ROUTE BEGIN' "$TEST_TMP/Caddyfile") -eq 1 ]]
grep -Fq 'reverse_proxy @psv1_turboflare 172.18.0.1:7555' "$TEST_TMP/Caddyfile"
! grep -Fq '172.18.0.1:7443' "$TEST_TMP/Caddyfile"

before=$(sha256sum "$TEST_TMP/Caddyfile" | awk '{print $1}')
if (run_node_caddy_route beeline other.example.ru 7444 "$TEST_TMP/Caddyfile" >/dev/null 2>&1); then
  echo '[FAIL] unrelated Caddy vhost was accepted' >&2
  exit 1
fi
after=$(sha256sum "$TEST_TMP/Caddyfile" | awk '{print $1}')
[[ "$before" == "$after" ]]

echo '[ OK ] Caddy route is idempotent, preserves SFTPGo and rejects unrelated vhosts'

cat > "$TEST_TMP/cdn-origin.conf" <<'EOF'
upstream xray_xhttp { server 127.0.0.1:10089; keepalive 128; }
server {
    listen 80 default_server;
    server_name _;
    location ^~ /static/getFile/video/segment.ts {
        proxy_pass http://xray_xhttp;
    }
    location / { return 200; }
}
server {
    listen 443 ssl default_server;
    server_name _;
    location ^~ /static/getFile/video/segment.ts {
        proxy_pass http://xray_xhttp;
    }
    location / { return 200; }
}
EOF

# Old TurboFlare direct upstream is migrated to the cascade port.
run_node_nginx_route turboflare file.example.ru 7443 "$TEST_TMP/cdn-origin.conf" >/dev/null
grep -Fq 'server 127.0.0.1:7443;' "$TEST_TMP/cdn-origin.conf"
grep -Fq '# PSV1-TURBOFLARE-LEGACY-UPSTREAM' "$TEST_TMP/cdn-origin.conf"
! grep -Fq 'server 127.0.0.1:10089;' "$TEST_TMP/cdn-origin.conf"

# A different path gets independent HTTP and HTTPS locations.
run_node_nginx_route yandex file.example.ru 7445 "$TEST_TMP/cdn-origin.conf" >/dev/null
[[ $(grep -Fc 'PSV1-YANDEX-ROUTE BEGIN' "$TEST_TMP/cdn-origin.conf") -eq 2 ]]
[[ $(grep -Fc 'proxy_pass http://127.0.0.1:7445;' "$TEST_TMP/cdn-origin.conf") -eq 2 ]]

# Re-running is idempotent and changes only the managed route target.
run_node_nginx_route yandex file.example.ru 7555 "$TEST_TMP/cdn-origin.conf" >/dev/null
[[ $(grep -Fc 'PSV1-YANDEX-ROUTE BEGIN' "$TEST_TMP/cdn-origin.conf") -eq 2 ]]
[[ $(grep -Fc 'proxy_pass http://127.0.0.1:7555;' "$TEST_TMP/cdn-origin.conf") -eq 2 ]]

# Beeline shares TurboFlare's path and must be rejected on this vhost.
before=$(sha256sum "$TEST_TMP/cdn-origin.conf" | awk '{print $1}')
if (run_node_nginx_route beeline file.example.ru 7444 "$TEST_TMP/cdn-origin.conf" >/dev/null 2>&1); then
  echo '[FAIL] same-path nginx collision was accepted' >&2
  exit 1
fi
after=$(sha256sum "$TEST_TMP/cdn-origin.conf" | awk '{print $1}')
[[ "$before" == "$after" ]]

echo '[ OK ] nginx route repairs legacy port, preserves independent paths and rejects collisions'
