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

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/sshd" <<'SH'
#!/usr/bin/env bash
printf 'port 2222\n'
for ((i=0; i<20000; i++)); do printf 'setting_%s value\n' "$i"; done
SH
chmod +x "$TEST_TMP/bin/sshd"
PATH="$TEST_TMP/bin:$PATH"
[[ "$(detect_ssh_port)" == 2222 ]] || fail 'configured SSH port was not detected'
pass 'SSH port detection drains sshd output without SIGPIPE'

cat > "$TEST_TMP/bin/sshd" <<'SH'
#!/usr/bin/env bash
printf 'permitrootlogin yes\n'
SH
chmod +x "$TEST_TMP/bin/sshd"
[[ "$(detect_ssh_port)" == 22 ]] || fail 'SSH fallback port must be 22 when no port is configured'
pass 'SSH port detection falls back to 22 when sshd has no port directive'
