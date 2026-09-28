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

INSTALL_PATH='/root/panel-script-v1.sh'
METHOD=timeweb
ORIGIN_TYPE=sftpgo
ORIGIN_PORT=8080
ORIGIN_DOMAIN=''
CDN_DOMAIN='cdn.example.ru'
USE_CLOUDFLARE=no
rm_manager_provider_steps timeweb 203.0.113.10 "$TEST_TMP/provider-steps.txt"
grep -Fq 'Стандарт мастера: источник 203.0.113.10:80 (IP-адрес), HTTPS к источнику ВЫКЛ' "$TEST_TMP/provider-steps.txt" \
  || fail 'Timeweb source must be public IP:80 over HTTP'
grep -Fq 'Если используешь существующий TLS-vhost на :443 (как в отдельном nginx-шаблоне), укажи 203.0.113.10:443 и включи HTTPS к источнику' "$TEST_TMP/provider-steps.txt" \
  || fail 'Timeweb instructions must explain the HTTPS source option for existing TLS origins'
grep -Fq 'Xray :10087 — внутренний upstream за reverse proxy' "$TEST_TMP/provider-steps.txt" \
  || fail 'Timeweb instructions must separate the Xray upstream from the CDN source'
grep -Fq 'Порт 10443 и путь /content/ova.txt из стороннего шаблона подходят только если именно такие порт и path заданы в активном Xray inbound' "$TEST_TMP/provider-steps.txt" \
  || fail 'Timeweb instructions must warn about custom inbound ports and paths'
grep -Fq 'SFTPGo должен уже работать' "$TEST_TMP/provider-steps.txt" \
  || fail 'SFTPGo choice must state that the service already has to exist'
! grep -Fq '127.0.0.1:8080' "$TEST_TMP/provider-steps.txt" \
  || fail 'provider instructions must not misrepresent the local SFTPGo port as the CDN source'
pass 'Timeweb source and existing SFTPGo are described separately'

[[ "$(rm_method_meta timeweb port)" == 10087 ]] || fail 'Timeweb method metadata must use Xray port 10087'
[[ "$(rm_method_meta timeweb path)" == '/content/media/stream.m3u8' ]] || fail 'Timeweb client path changed unexpectedly'
[[ "$(method_server_path timeweb)" == '/content/media/' ]] || fail 'Timeweb inbound server path changed unexpectedly'
pass 'Timeweb default port and client path remain aligned with its preset'

write_apply_proxy_route_script "$TEST_TMP/APPLY-ON-RELAY.sh" yandex relay.example.ru 7445 '/uploadfiles-cascade/'
[[ "$(head -n 1 "$TEST_TMP/APPLY-ON-RELAY.sh")" == '#!/usr/bin/env bash' ]] \
  || fail 'generated route script must have a Bash shebang'
bash -n "$TEST_TMP/APPLY-ON-RELAY.sh" || fail 'generated route script must parse as Bash'
grep -Fq 'export PSV1_ROUTE_PATH=/uploadfiles-cascade/' "$TEST_TMP/APPLY-ON-RELAY.sh" \
  || fail 'cascade route path was not preserved in the generated script'
grep -Fq 'exec /root/panel-script-v1.sh --node-proxy-route yandex relay.example.ru 7445' "$TEST_TMP/APPLY-ON-RELAY.sh" \
  || fail 'generated route command has wrong target or arguments'
pass 'generated APPLY script is directly runnable and preserves cascade arguments'

echo 'All Timeweb/origin tests passed.'
