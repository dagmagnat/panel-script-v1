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
