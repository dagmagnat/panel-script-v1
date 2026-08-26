#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# panel-script-v1 — public GitHub installer for CDN/XHTTP nodes and panels.
# Supported OS: Ubuntu 22.04 / 24.04
# Panels:
#   - 3x-ui compatibility branch: v3.3.1 (VK / Yandex / TurboFlare)
#   - Remnawave: 3.3.0 manual-tested by default (all 6 CDN methods)
#
# This installer deliberately keeps each CDN preset separate. Do not mix fields
# between providers: path/padding/uplink settings are provider-specific.

INSTALLER_VERSION="1.2.3"
STATE_SCHEMA_CURRENT="1"
PRESET="${INSTALLER_PRESET:-}"

XUI_COMPAT_VERSION="v3.3.1"
REMNA_MANUAL_VERSION="3.3.0"
REMNA_NEWER_VERSION="3.3.2"
XRAY_MANUAL_VERSION="26.7.28"

PROJECT_NAME="panel-script-v1"
PROJECT_REPO="dagmagnat/panel-script-v1"
PROJECT_BRANCH="main"
PROJECT_RAW="https://raw.githubusercontent.com/${PROJECT_REPO}/${PROJECT_BRANCH}"
INSTALL_PATH="/root/panel-script-v1.sh"

STATE_DIR="/root/.panel-script-v1"
LEGACY_STATE_DIR="/root/.cdn-xhttp-installer"
STATE_FILE="$STATE_DIR/config.env"
MARK_DIR="$STATE_DIR/markers"
LOG_FILE="$STATE_DIR/install.log"
OUT_DIR="/root/panel-script-v1-output"
RESULT_FILE="$OUT_DIR/result.txt"
BACKUP_DIR="$STATE_DIR/backups"
WEBROOT="/var/www/cdn-placeholder"
ACME_ROOT="/var/www/certbot"
SELF_CERT_DIR="/etc/nginx/cdn-installer-selfsigned"

# Preserve unfinished state from pre-GitHub v0.9 if it exists.
if [[ ! -e "$STATE_DIR" && -d "$LEGACY_STATE_DIR" ]]; then
  cp -a "$LEGACY_STATE_DIR" "$STATE_DIR" 2>/dev/null || true
fi
mkdir -p "$STATE_DIR" "$MARK_DIR" "$OUT_DIR" "$BACKUP_DIR"
chmod 700 "$STATE_DIR" "$OUT_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_MAGENTA='\033[0;35m'
info(){ echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok(){ echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
die(){ echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; exit 1; }
ui_title(){ echo; echo -e "${C_BOLD}${C_CYAN}===== $* =====${C_RESET}"; }
auto_done(){ echo -e "${C_GREEN}[АВТО]${C_RESET} $*"; }
manual_do(){ echo -e "${C_YELLOW}[ВРУЧНУЮ]${C_RESET} $*"; }
user_prepare(){ echo -e "${C_MAGENTA}[ПОДГОТОВКА]${C_RESET} $*"; }
check_do(){ echo -e "${C_CYAN}[ПРОВЕРКА]${C_RESET} $*"; }
danger(){ echo -e "${C_RED}[ОСТОРОЖНО]${C_RESET} $*"; }
mark(){ touch "$MARK_DIR/$1"; }
marked(){ [[ -f "$MARK_DIR/$1" ]]; }

on_error(){
  local rc=$?
  echo
  warn "Установка остановилась на строке $1 (код $rc)."
  warn "Ответы и прогресс сохранены: $STATE_FILE"
  warn "После исправления снова запусти этот же файл — он продолжит установку."
  warn "Лог: $LOG_FILE"
  exit "$rc"
}
trap 'on_error $LINENO' ERR

[[ $EUID -eq 0 ]] || die "Запусти скрипт от root."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Скрипт рассчитан на Ubuntu."
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) warn "Ubuntu ${VERSION_ID:-unknown}: основной сценарий проверяется под 22.04/24.04." ;; esac

valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
ask_yes_no(){
  local __var="$1" label="$2" default="${3:-yes}" ans=""
  if [[ "$default" == yes ]]; then read -r -p "$label [Y/n]: " ans; ans="${ans:-y}"; else read -r -p "$label [y/N]: " ans; ans="${ans:-n}"; fi
  case "${ans,,}" in y|yes|д|да) printf -v "$__var" '%s' yes ;; *) printf -v "$__var" '%s' no ;; esac
}
ask_domain(){
  local __var="$1" label="$2" current="${3:-}" example="$4" v=""
  while true; do
    if [[ -n "$current" ]]; then read -r -p "$label [$current]: " v; v="${v:-$current}"; else read -r -p "$label (пример: $example): " v; fi
    v="${v,,}"
    if valid_domain "$v"; then printf -v "$__var" '%s' "$v"; return; fi
    warn "Некорректный домен. Пример: $example"
  done
}
ask_optional_domain(){
  local __var="$1" label="$2" current="${3:-}" example="$4" v=""
  while true; do
    if [[ -n "$current" ]]; then read -r -p "$label [$current] (Enter = оставить): " v; v="${v:-$current}"; else read -r -p "$label (Enter = без домена; пример: $example): " v; fi
    v="${v,,}"
    if [[ -z "$v" ]] || valid_domain "$v"; then printf -v "$__var" '%s' "$v"; return; fi
    warn "Некорректный домен."
  done
}
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
ask_port(){
  local __var="$1" label="$2" current="${3:-2222}" v=""
  while true; do
    read -r -p "$label [$current]: " v
    v="${v:-$current}"
    if valid_port "$v"; then printf -v "$__var" '%s' "$v"; return; fi
    warn "Некорректный порт. Введи число от 1 до 65535."
  done
}
ensure_remna_node_port(){
  if [[ "${PANEL_KIND:-}" == remna && ( "${REMNA_ROLE:-}" == node || "${REMNA_ROLE:-}" == both ) && -z "${REMNA_NODE_PORT:-}" ]]; then
    echo
    warn "Node Port не сохранён (это нормально после обновления старой версии скрипта)."
    echo "Введи ТОЧНО тот Node Port, который указан в карточке ноды Remnawave."
    echo "Он должен совпадать в панели и в NODE_PORT контейнера ноды."
    ask_port REMNA_NODE_PORT "Node Port из Remnawave" "2222"
    save_state
  fi
}
random_password(){ openssl rand -base64 24 | tr -d '\n' | tr '/+' 'Aa'; }
random_path(){ openssl rand -hex 8; }

save_state(){
  local t="$STATE_FILE.tmp"
  umask 077
  {
    printf 'STATE_SCHEMA=%q\n' "$STATE_SCHEMA_CURRENT"
    for k in PANEL_KIND REMNA_ROLE METHOD REMNA_VERSION REMNA_NODE_PORT REMNA_EXISTING_PANEL_SIDE_BY_SIDE XUI_VERSION UPGRADE_XUI_XRAY XUI_EXISTING PANEL_DOMAIN ORIGIN_DOMAIN CDN_DOMAIN USE_CLOUDFLARE ENABLE_UFW ENABLE_BBR CASCADE CASCADE_METHOD CASCADE_RELAY_NODE_UUID CASCADE_EXIT_MODE CASCADE_EXIT_NODE_UUID CASCADE_EXIT_NODE_UUIDS CASCADE_RELAY_IP CASCADE_EXIT_IP CASCADE_EXIT_IPS CASCADE_STRATEGY CASCADE_BRIDGE_UUID CASCADE_STATUS LE_EMAIL PANEL_IP REMNA_SECRET_KEY XUI_USER XUI_PASS XUI_PANEL_PORT XUI_PATH; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } > "$t"
  mv "$t" "$STATE_FILE"; chmod 600 "$STATE_FILE"
  umask 022
}
load_state(){
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ "${STATE_SCHEMA:-0}" == "$STATE_SCHEMA_CURRENT" ]] || { mv "$STATE_FILE" "$STATE_FILE.old.$(date +%Y%m%d-%H%M%S)"; rm -rf "$MARK_DIR"; mkdir -p "$MARK_DIR"; return 1; }
  return 0
}

method_title(){
  case "$1" in
    vk) echo "VK Cloud" ;; yandex) echo "Yandex Cloud" ;; beeline) echo "Beeline CDN/CDNvideo" ;;
    timeweb) echo "Timeweb CDN" ;; selectel) echo "Selectel CDN" ;; turboflare) echo "TurboFlare" ;;
    none) echo "Без CDN / нода для каскада" ;; *) echo "$1" ;;
  esac
}

local_remna_panel_present(){
  if command -v docker >/dev/null 2>&1 && docker inspect remnawave >/dev/null 2>&1; then
    return 0
  fi
  [[ -f /opt/remnawave/docker-compose.yml && -f /opt/remnawave/.env ]]
}

is_side_by_side_remna_node(){
  [[ "${PANEL_KIND:-}" == remna && "${REMNA_ROLE:-}" == node ]] || return 1
  [[ "${REMNA_EXISTING_PANEL_SIDE_BY_SIDE:-no}" == yes ]] && return 0
  local_remna_panel_present
}

is_bare_remna_node(){
  [[ "${PANEL_KIND:-}" == remna && "${REMNA_ROLE:-}" == node && "${METHOD:-none}" == none ]]
}

nginx_foreign_enabled_sites(){
  [[ -d /etc/nginx/sites-enabled ]] || return 1
  find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
    | grep -Ev '^(default|cdn-bootstrap\.conf|cdn-origin\.conf|remnawave-panel\.conf)$' \
    | grep -q .
}

method_port(){
  case "$PANEL_KIND:$METHOD" in
    3xui:vk) echo 2053 ;; 3xui:yandex) echo 4443 ;; 3xui:turboflare) echo 10089 ;;
    remna:vk) echo 10085 ;; remna:yandex) echo 4443 ;; remna:beeline) echo 10086 ;; remna:timeweb) echo 10087 ;; remna:selectel) echo 10088 ;; remna:turboflare) echo 10089 ;;
    *) die "Неизвестная комбинация панели и метода." ;;
  esac
}
method_server_path(){
  case "$METHOD" in
    vk) echo "/content/media/stream/" ;; yandex) echo "/uploadfiles/" ;; beeline|turboflare) echo "/static/getFile/video/segment.ts" ;;
    timeweb) echo "/content/media/" ;; selectel) echo "/api/uploadFile/" ;;
  esac
}
method_client_path(){
  if [[ "$METHOD" == timeweb ]]; then echo "/content/media/stream.m3u8"; else method_server_path; fi
}
method_nginx_style(){ case "$METHOD" in beeline|turboflare) echo rewrite ;; *) echo prefix ;; esac; }


# -----------------------------------------------------------------------------
# Remnawave panel manager
# -----------------------------------------------------------------------------
# This mode runs on the CENTRAL PANEL server. It never reinstalls Remnawave and
# never deletes existing profiles/hosts/nodes. It can add a CDN profile to an
# already-created node through the local Remnawave API. If the API contract of
# the installed panel differs, it stops at that operation and leaves ready JSON
# files plus manual steps instead of overwriting anything.
RM_MANAGER_TOKEN_FILE="$STATE_DIR/remna-manager.token"
RM_MANAGER_DIR="$OUT_DIR/remna-methods"
RM_API_BASE="${RM_API_BASE:-}"
RM_API_INSECURE="${RM_API_INSECURE:-no}"
mkdir -p "$RM_MANAGER_DIR"

rm_try_api_base(){
  local base="${1%/}" code=""
  [[ -n "$base" ]] || return 1
  code=$(curl -sS -o /dev/null --connect-timeout 2 --max-time 5 -w '%{http_code}' "${base}/api/auth/status" 2>/dev/null || true)
  if [[ -n "$code" && "$code" != 000 ]]; then
    RM_API_BASE="$base"
    RM_API_INSECURE=no
    return 0
  fi
  code=$(curl -ksS -o /dev/null --connect-timeout 2 --max-time 5 -w '%{http_code}' "${base}/api/auth/status" 2>/dev/null || true)
  if [[ -n "$code" && "$code" != 000 ]]; then
    RM_API_BASE="$base"
    RM_API_INSECURE=yes
    return 0
  fi
  return 1
}

rm_discover_api_base(){
  local c hp ip candidate

  if [[ -n "${RM_API_BASE:-}" ]] && rm_try_api_base "$RM_API_BASE"; then return 0; fi

  # Classic compose used by earlier versions of this installer.
  if rm_try_api_base "http://127.0.0.1:3000"; then return 0; fi

  # Remnawave can also be published on another localhost port or only inside a
  # Docker network. Discover both layouts instead of assuming :3000 on host.
  if command -v docker >/dev/null 2>&1; then
    for c in remnawave remnawave-rest-api; do
      docker inspect "$c" >/dev/null 2>&1 || continue
      hp=$(docker inspect -f '{{with (index .NetworkSettings.Ports "3000/tcp")}}{{(index . 0).HostPort}}{{end}}' "$c" 2>/dev/null || true)
      if [[ "$hp" =~ ^[0-9]+$ ]] && rm_try_api_base "http://127.0.0.1:${hp}"; then return 0; fi
      ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" 2>/dev/null || true)
      if [[ -n "$ip" ]] && rm_try_api_base "http://${ip}:3000"; then return 0; fi
    done
  fi

  # When manager is launched via a fresh process, PANEL_DOMAIN only exists if
  # saved state was loaded. v1.1.1 forgot to do this, which is why a working
  # panel behind nginx could be reported as "not found".
  if [[ -n "${PANEL_DOMAIN:-}" ]]; then
    candidate="https://${PANEL_DOMAIN}"
    if rm_try_api_base "$candidate"; then return 0; fi
    candidate="http://${PANEL_DOMAIN}"
    if rm_try_api_base "$candidate"; then return 0; fi
  fi

  return 1
}

rm_panel_detected(){
  # API availability matters more than a particular Docker layout. This also
  # supports panels installed by older/newer Remnawave compose files.
  rm_discover_api_base
}

rm_panel_version(){
  local line=""
  if [[ -f /opt/remnawave/docker-compose.yml ]]; then
    line=$(grep -m1 -Eo 'remnawave/backend:[A-Za-z0-9._-]+' /opt/remnawave/docker-compose.yml 2>/dev/null || true)
    [[ -n "$line" ]] && printf '%s\n' "${line#*:}" && return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    line=$(docker inspect -f '{{.Config.Image}}' remnawave 2>/dev/null || docker inspect -f '{{.Config.Image}}' remnawave-rest-api 2>/dev/null || true)
    [[ "$line" == *:* ]] && printf '%s\n' "${line##*:}" && return 0
  fi
  return 1
}

rm_normalize_token(){
  local token="${1:-}"
  token="${token//$'\r'/}"
  token="${token//$'\n'/}"
  token="${token#Authorization: Bearer }"
  token="${token#authorization: bearer }"
  token="${token#Bearer }"
  token="${token#bearer }"
  # Remove accidental surrounding quotes without touching token contents.
  if [[ ${#token} -ge 2 && "$token" == \"*\" ]]; then token="${token:1:${#token}-2}"; fi
  if [[ ${#token} -ge 2 && "$token" == \'*\' ]]; then token="${token:1:${#token}-2}"; fi
  printf '%s' "$token"
}

rm_api(){
  local method="$1"
  local path="$2"
  local token="${3:-}"
  local data="${4:-}"
  local url="${RM_API_BASE%/}${path}"
  local auth=""
  local args=(-sS --max-time 20 -X "$method" "$url" -H 'Content-Type: application/json' -H 'X-Remnawave-Client-Type: browser')
  [[ "${RM_API_INSECURE:-no}" == yes ]] && args+=(-k)
  if [[ -n "$token" ]]; then
    token=$(rm_normalize_token "$token")
    auth="Bearer $token"
    args+=(-H "Authorization: $auth")
  fi
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}"
}

rm_api_fetch_to_file(){
  local method="$1"
  local path="$2"
  local token="${3:-}"
  local out="$4"
  local data="${5:-}"
  local url="${RM_API_BASE%/}${path}"
  local code=""
  local args=(-sS --max-time 30 -o "$out" -w '%{http_code}' -X "$method" "$url" -H 'Content-Type: application/json' -H 'X-Remnawave-Client-Type: browser')
  [[ "${RM_API_INSECURE:-no}" == yes ]] && args+=(-k)
  if [[ -n "$token" ]]; then
    token=$(rm_normalize_token "$token")
    args+=(-H "Authorization: Bearer $token")
  fi
  [[ -n "$data" ]] && args+=(-d "$data")
  code=$(curl "${args[@]}" 2>/dev/null || printf '000')
  printf '%s' "$code"
}

rm_admin_jwt_prompt(){
  local user pass body resp token
  read -r -p "Логин администратора: " user
  read -r -s -p "Пароль администратора: " pass; echo >&2
  body=$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')
  resp=$(rm_api POST /api/auth/login "" "$body" 2>/dev/null || true)
  token=$(jq -r '.response.accessToken // .accessToken // empty' <<<"$resp" 2>/dev/null || true)
  [[ -n "$token" ]] || { warn "Не удалось получить admin JWT. Проверь логин/пароль." >&2; return 1; }
  printf '%s' "$token"
}

rm_api_http_probe(){
  local token="$1" body_file code url="${RM_API_BASE%/}/api/config-profiles"
  local args=(-sS --max-time 20 -o)
  body_file=$(mktemp)
  token=$(rm_normalize_token "$token")
  if [[ "${RM_API_INSECURE:-no}" == yes ]]; then
    code=$(curl -k -sS --max-time 20 -o "$body_file" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H 'X-Remnawave-Client-Type: browser' \
      -H "Authorization: Bearer $token" "$url" 2>/dev/null || printf '000')
  else
    code=$(curl -sS --max-time 20 -o "$body_file" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H 'X-Remnawave-Client-Type: browser' \
      -H "Authorization: Bearer $token" "$url" 2>/dev/null || printf '000')
  fi
  printf '%s\n' "$code"
  cat "$body_file"
  rm -f "$body_file"
}

rm_token_valid(){
  local token="$1" probe code body
  token=$(rm_normalize_token "$token")
  [[ -n "$token" ]] || return 1
  # A UUID shown in token details is the token record UUID, not the API secret.
  [[ "$token" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && return 3

  # Do not validate authorization by one particular response layout. Remnawave
  # has changed list wrappers between releases. HTTP 2xx + valid JSON without
  # an API error is enough to prove the token was accepted.
  probe=$(rm_api_http_probe "$token" 2>/dev/null || true)
  code=$(sed -n '1p' <<<"$probe")
  body=$(sed '1d' <<<"$probe")
  [[ "$code" =~ ^2[0-9][0-9]$ ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$body" || return 5
  if jq -e '((.statusCode? // 200) | tonumber? // 200) >= 400 or ((.errorCode? // null) != null) or (((.message? // "")|tostring) | test("unauthorized|forbidden";"i"))' >/dev/null 2>&1 <<<"$body"; then
    return 1
  fi
  return 0
}

rm_get_token(){
  local token="" choice user pass body resp
  if [[ -s "$RM_MANAGER_TOKEN_FILE" ]]; then
    token=$(cat "$RM_MANAGER_TOKEN_FILE")
    if rm_token_valid "$token"; then
      ok "Сохранённый токен панели работает." >&2
      printf '%s' "$token"
      return 0
    fi
    warn "Сохранённый токен панели истёк/не подходит — запрошу вход снова." >&2
    rm -f "$RM_MANAGER_TOKEN_FILE"
  fi
  echo >&2
  echo "Как войти в Remnawave API (${RM_API_BASE})?" >&2
  echo "  1 — логин и пароль администратора панели (проще)" >&2
  echo "  2 — вставить API token" >&2
  echo "  3 — без API: только подготовить JSON и пошаговую инструкцию" >&2
  echo "  0 — назад" >&2
  read -r -p "Выбор [1]: " choice; choice="${choice:-1}"
  case "$choice" in
    0) return 10 ;;
    3) return 2 ;;
    2)
      read -r -s -p "API token (НЕ UUID записи токена): " token; echo >&2
      token=$(rm_normalize_token "$token")
      if [[ "$token" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        warn "Введён UUID записи API Token, а не сам секретный API token. UUID из окна сведений для Authorization не подходит." >&2
        echo "Создай новый API Token в Settings → API Tokens и скопируй именно выданное значение token; либо выбери вход логином/паролем." >&2
        return 4
      fi
      ;;
    *)
      read -r -p "Логин администратора: " user
      read -r -s -p "Пароль администратора: " pass; echo >&2
      body=$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')
      resp=$(rm_api POST /api/auth/login "" "$body" 2>/dev/null || true)
      token=$(jq -r '.response.accessToken // .accessToken // empty' <<<"$resp" 2>/dev/null || true)
      if [[ -z "$token" ]]; then
        warn "Не удалось получить токен по логину/паролю. Ответ панели: $(jq -r '.message // .error // "неизвестная ошибка"' <<<"$resp" 2>/dev/null || echo error)" >&2
        return 1
      fi
      ;;
  esac
  if rm_token_valid "$token"; then
    :
  else
    local vrc=$? probe code body msg
    if [[ $vrc -eq 3 ]]; then
      warn "Введён UUID записи API Token, а не секретный token." >&2
      return 4
    fi
    if [[ $vrc -eq 5 ]]; then
      warn "Панель ответила HTTP 2xx, но тело ответа не JSON. Проверь reverse proxy/API route; токен здесь не доказан и не опровергнут." >&2
      return 2
    fi
    probe=$(rm_api_http_probe "$token" 2>/dev/null || true)
    code=$(sed -n '1p' <<<"$probe")
    body=$(sed '1d' <<<"$probe")
    msg=$(jq -r '.message // .error // .errorCode // empty' <<<"$body" 2>/dev/null || true)
    warn "Проверка API token не прошла: /api/config-profiles → HTTP ${code:-unknown}${msg:+, $msg}." >&2
    echo "Если ты вставлял строку из поля UUID (xxxxxxxx-xxxx-...), это НЕ API token." >&2
    echo "Можно сразу выбрать вход логином/паролем — пароль отправляется только твоей панели по HTTPS." >&2
    return 2
  fi
  umask 077; printf '%s\n' "$token" > "$RM_MANAGER_TOKEN_FILE"; chmod 600 "$RM_MANAGER_TOKEN_FILE"; umask 022
  printf '%s' "$token"
}

rm_pick_entity_array(){
  # Usage: rm_pick_entity_array <kind>. Reads one API JSON response on stdin.
  # Remnawave has changed list wrappers between releases.
  local kind="$1"
  jq -c --arg kind "$kind" '
    def nodeish($o):
      ($o|type)=="object" and ($o.uuid? != null) and ($o.name? != null) and
      (($o.address? != null) or ($o.nodeAddress? != null) or ($o.host? != null) or ($o.ip? != null));
    def looks($k; $o):
      ($o|type)=="object" and
      (if $k=="nodes" then nodeish($o)
       elif $k=="profiles" then (($o.uuid? != null) and ($o.name? != null))
       elif $k=="hosts" then (($o.uuid? != null) and (($o.address? != null) or ($o.remark? != null) or ($o.inbound? != null)))
       elif $k=="squads" then (($o.uuid? != null) and ($o.name? != null))
       else false end);
    def normalize_node:
      . + {
        address: (.address // .nodeAddress // .host // .ip // ""),
        port: (.port // .nodePort // 2222),
        isConnected: (.isConnected // .is_connected // .connected // false)
      };
    (([.. | arrays | select(length>0 and looks($kind; .[0]))] | sort_by(length) | reverse | .[0]) // [])
    | if $kind=="nodes" then map(normalize_node) else . end
  ' 2>/dev/null || echo '[]'
}

rm_nodes_json(){
  local token="$1" f="$RM_MANAGER_DIR/last-nodes-response.json" meta="$RM_MANAGER_DIR/last-nodes-http.txt"
  local tmp code path parsed saw_json=no
  : > "$meta"
  for path in '/api/nodes' '/api/nodes?start=0&size=100' '/api/nodes?start=0&size=1000'; do
    tmp=$(mktemp)
    code=$(rm_api_fetch_to_file GET "$path" "$token" "$tmp")
    printf 'path=%s http=%s bytes=%s\n' "$path" "$code" "$(wc -c < "$tmp" 2>/dev/null || echo 0)" >> "$meta"
    if [[ -s "$tmp" ]] && jq -e . "$tmp" >/dev/null 2>&1; then
      saw_json=yes
      cp "$tmp" "$f"
      chmod 600 "$f" 2>/dev/null || true
      parsed=$(rm_pick_entity_array nodes < "$tmp")
      if jq -e 'length > 0' <<<"$parsed" >/dev/null 2>&1; then
        rm -f "$tmp"
        printf '%s\n' "$parsed"
        return 0
      fi
    elif [[ -s "$tmp" ]]; then
      cp "$tmp" "$f"
      chmod 600 "$f" 2>/dev/null || true
    fi
    rm -f "$tmp"
  done
  [[ -e "$f" ]] || : > "$f"
  chmod 600 "$f" 2>/dev/null || true
  printf '[]\n'
  [[ "$saw_json" == yes ]] && return 2 || return 3
}

rm_profiles_json(){
  local token="$1" r f="$RM_MANAGER_DIR/last-profiles-response.json"
  r=$(rm_api GET /api/config-profiles "$token" 2>/dev/null || true)
  printf '%s\n' "$r" > "$f"; chmod 600 "$f" 2>/dev/null || true
  rm_pick_entity_array profiles <<<"$r"
}

rm_hosts_json(){
  local token="$1" r f="$RM_MANAGER_DIR/last-hosts-response.json"
  r=$(rm_api GET /api/hosts "$token" 2>/dev/null || true)
  printf '%s\n' "$r" > "$f"; chmod 600 "$f" 2>/dev/null || true
  rm_pick_entity_array hosts <<<"$r"
}

rm_internal_squads_json(){
  local token="$1" r f="$RM_MANAGER_DIR/last-internal-squads-response.json"
  r=$(rm_api GET /api/internal-squads "$token" 2>/dev/null || true)
  printf '%s\n' "$r" > "$f"; chmod 600 "$f" 2>/dev/null || true
  rm_pick_entity_array squads <<<"$r"
}

rm_choose_node(){
  local token="$1" exclude_uuid="${2:-}" nodes filtered n count i choice nrc=0
  if nodes=$(rm_nodes_json "$token"); then nrc=0; else nrc=$?; fi
  [[ $nrc -eq 0 ]] || return "$nrc"
  if [[ -n "$exclude_uuid" ]]; then
    filtered=$(jq -c --arg x "$exclude_uuid" '[.[]? | select((.uuid // "") != $x)]' <<<"$nodes")
  else
    filtered="$nodes"
  fi
  count=$(jq 'length' <<<"$filtered")
  if (( count == 0 )); then
    return 2
  fi
  echo >&2
  if [[ -n "$exclude_uuid" ]]; then
    echo "Ноды, доступные для выбора (предыдущая нода исключена):" >&2
  else
    echo "Ноды, которые уже есть в панели:" >&2
  fi
  i=1
  while (( i <= count )); do
    n=$(jq -c ".[${i}-1]" <<<"$filtered")
    printf '  %d — %s | %s:%s | connected=%s\n' "$i" \
      "$(jq -r '.name // "без имени"' <<<"$n")" \
      "$(jq -r '.address // "?"' <<<"$n")" \
      "$(jq -r '.port // 2222' <<<"$n")" \
      "$(jq -r '.isConnected // .is_connected // false' <<<"$n")" >&2
    ((i++))
  done
  echo "  0 — назад" >&2
  while true; do
    read -r -p "Выбери ноду [1]: " choice; choice="${choice:-1}"
    [[ "$choice" == 0 ]] && return 1
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) && break
    warn "Выбери число от 1 до $count или 0 для возврата." >&2
  done
  jq -c ".[${choice}-1]" <<<"$filtered"
}


rm_choose_multiple_nodes(){
  local token="$1" exclude_uuid="${2:-}" nodes filtered count i n raw idx item result='[]' nrc=0
  local -a picks=()
  if nodes=$(rm_nodes_json "$token"); then nrc=0; else nrc=$?; fi
  [[ $nrc -eq 0 ]] || return "$nrc"
  filtered=$(jq -c --arg x "$exclude_uuid" '[.[]? | select((.uuid // "") != $x)]' <<<"$nodes")
  count=$(jq 'length' <<<"$filtered")
  (( count > 0 )) || return 2

  echo >&2
  echo "Ноды, доступные как exit (relay уже исключён):" >&2
  i=1
  while (( i <= count )); do
    n=$(jq -c ".[${i}-1]" <<<"$filtered")
    printf '  %d — %s | %s:%s | connected=%s\n' "$i" \
      "$(jq -r '.name // "без имени"' <<<"$n")" \
      "$(jq -r '.address // "?"' <<<"$n")" \
      "$(jq -r '.port // 2222' <<<"$n")" \
      "$(jq -r '.isConnected // .is_connected // false' <<<"$n")" >&2
    ((i++))
  done

  echo "  0 — назад" >&2
  while true; do
    read -r -p "Выбери exit-ноды через запятую (например 1,3,4; 0 = назад): " raw
    raw="${raw// /}"
    [[ "$raw" == 0 ]] && return 1
    [[ -n "$raw" ]] || { warn "Нужно выбрать хотя бы одну exit-ноду." >&2; continue; }
    IFS=',' read -r -a picks <<<"$raw"
    result='[]'
    local bad=no
    for idx in "${picks[@]}"; do
      if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
        bad=yes; break
      fi
      item=$(jq -c ".[${idx}-1]" <<<"$filtered")
      if jq -e --arg u "$(jq -r '.uuid' <<<"$item")" 'any(.[]?; .uuid==$u)' >/dev/null 2>&1 <<<"$result"; then
        continue
      fi
      result=$(jq -c --argjson a "$result" --argjson n "$item" '$a + [$n]' <<< '{}')
    done
    if [[ "$bad" == yes ]]; then
      warn "Есть неверный номер. Используй значения от 1 до $count." >&2
      continue
    fi
    (( $(jq 'length' <<<"$result") > 0 )) || { warn "Нужно выбрать хотя бы одну exit-ноду." >&2; continue; }
    printf '%s\n' "$result"
    return 0
  done
}

rm_method_inbound_json(){
  local method="$1" tag="$2" base
  # Эти шесть пресетов повторяют соответствующие Remnawave-мануалы буквально.
  # VK/Yandex держат параметры прямо в xhttpSettings; остальные четыре — в extra.
  case "$method" in
    vk) base='{"tag":"cdn-stream","port":10085,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","mode":"packet-up","path":"/content/media/stream/","noSSEHeader":false,"xPaddingKey":"_token","xPaddingBytes":"16-64","xPaddingHeader":"X-Signature","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxBufferedPosts":50,"scMaxEachPostBytes":"500000-1000000","scMinPostsIntervalMs":"50-150","scStreamUpServerSecs":"60-180","serverMaxHeaderBytes":0,"xmux":{"cMaxReuseTimes":"0","maxConnections":"1","hKeepAlivePeriod":0,"hMaxRequestTimes":"300-600","hMaxReusableSecs":"900-1800"}}}}' ;;
    yandex) base='{"tag":"yasha","port":4443,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"routeOnly":false,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/uploadfiles/","xPaddingKey":"_dc","xPaddingHeader":"X-Cache","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader","uplinkHTTPMethod":"get"}}}' ;;
    beeline) base='{"tag":"cdn-beeline","port":10086,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/static/getFile/video/segment.ts","extra":{"xmux":{"maxConcurrency":"1"},"seqKey":"chunk_id","sessionKey":"auth","noSSEHeader":true,"noGRPCHeader":true,"seqPlacement":"query","sessionIDKey":"auth","sessionIDLength":"16-32","sessionPlacement":"query","sessionIDPlacement":"query","xPaddingBytes":"50-150","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"header","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxBufferedPosts":100,"scMaxEachPostBytes":3000000,"scMinPostsIntervalMs":"5-10","serverMaxHeaderBytes":32768}}}}' ;;
    timeweb) base='{"tag":"cdn-timeweb","port":10087,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/content/media/","extra":{"sessionIDPlacement":"query","sessionIDKey":"sid","seqPlacement":"query","seqKey":"offset","noSSEHeader":false,"uplinkHTTPMethod":"GET","uplinkDataPlacement":"header","uplinkDataKey":"X-Playback-Token","xPaddingKey":"q","xPaddingBytes":"48-256","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","scMaxEachPostBytes":"4096-16384","scMinPostsIntervalMs":"1-8","serverMaxHeaderBytes":32768}}}}' ;;
    selectel) base='{"tag":"cdn-selectel","port":10088,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/api/uploadFile/","extra":{"seqKey":"page","seqPlacement":"query","noSSEHeader":false,"sessionIDKey":"X-Request-Id","sessionIDPlacement":"header","uplinkHTTPMethod":"POST","uplinkDataKey":"X-Payload","uplinkDataPlacement":"body","xPaddingKey":"q","xPaddingBytes":"80-240","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","scMaxEachPostBytes":"65536-262144","scMinPostsIntervalMs":"20-50","serverMaxHeaderBytes":32768}}}}' ;;
    turboflare) base='{"tag":"cdn-turboflare","port":10089,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/static/getFile/video/segment.ts","extra":{"xmux":{"maxConcurrency":"1"},"seqKey":"chunk_id","sessionKey":"auth","noSSEHeader":true,"noGRPCHeader":true,"seqPlacement":"query","sessionIDKey":"auth","sessionPlacement":"query","sessionIDPlacement":"query","xPaddingBytes":"50-150","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"header","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxBufferedPosts":100,"scMaxEachPostBytes":3000000,"scMinPostsIntervalMs":"5-10","serverMaxHeaderBytes":32768}}}}' ;;
    *) return 1 ;;
  esac
  jq -c --arg tag "$tag" '.tag=$tag' <<<"$base"
}

rm_method_host_extra_json(){
  local method="$1" inbound="$2"
  case "$method" in
    vk)
      jq -nc --argjson x "$(jq -c '.streamSettings.xhttpSettings' <<<"$inbound")" '$x | {xmux,noSSEHeader,xPaddingKey,xPaddingBytes,xPaddingHeader,xPaddingMethod,xPaddingObfsMode,xPaddingPlacement,uplinkHTTPMethod,uplinkDataPlacement,scMaxEachPostBytes,scMinPostsIntervalMs,scStreamUpServerSecs}'
      ;;
    yandex)
      # В Yandex-мануале xhttpExtraParams — 7 полей, включая mode.
      jq -nc --argjson x "$(jq -c '.streamSettings.xhttpSettings' <<<"$inbound")" '$x | {mode,xPaddingKey,xPaddingHeader,xPaddingMethod,xPaddingObfsMode,xPaddingPlacement,uplinkHTTPMethod}'
      ;;
    *) jq -c '.streamSettings.xhttpSettings.extra' <<<"$inbound" ;;
  esac
}

rm_method_meta(){
  local method="$1" key="$2"
  case "$method:$key" in
    vk:path) echo '/content/media/stream/' ;; vk:alpn) echo 'h2' ;; vk:fp) echo 'firefox' ;;
    yandex:path) echo '/uploadfiles/' ;; yandex:alpn) echo 'h3,h2,http/1.1' ;; yandex:fp) echo 'random' ;;
    beeline:path) echo '/static/getFile/video/segment.ts' ;; beeline:alpn) echo 'h2' ;; beeline:fp) echo 'firefox' ;;
    timeweb:path) echo '/content/media/stream.m3u8' ;; timeweb:alpn) echo 'h2,http/1.1' ;; timeweb:fp) echo 'random' ;;
    selectel:path) echo '/api/uploadFile/' ;; selectel:alpn) echo 'h2' ;; selectel:fp) echo 'random' ;;
    turboflare:path) echo '/static/getFile/video/segment.ts' ;; turboflare:alpn) echo 'h2,http/1.1' ;; turboflare:fp) echo 'firefox' ;;
  esac
}

rm_manager_choose_method(){
  local a
  echo >&2
  echo "Какой CDN добавить в существующую панель?" >&2
  echo "  1 — VK Cloud" >&2
  echo "  2 — Yandex Cloud" >&2
  echo "  3 — Beeline / CDNvideo" >&2
  echo "  4 — Timeweb" >&2
  echo "  5 — Selectel" >&2
  echo "  6 — TurboFlare" >&2
  echo "  0 — Назад" >&2
  while true; do
    read -r -p "Выбор [6]: " a; a="${a:-6}"
    case "$a" in 1) echo vk; return ;; 2) echo yandex; return ;; 3) echo beeline; return ;; 4) echo timeweb; return ;; 5) echo selectel; return ;; 6) echo turboflare; return ;; 0) return 1 ;; esac
  done
}

rm_manager_collect_domains(){
  local method="$1"
  ORIGIN_DOMAIN=""; CDN_DOMAIN=""
  case "$method" in
    turboflare)
      ask_domain CDN_DOMAIN "Домен TurboFlare, который будет в клиентском ключе" "" "media-example.org"
      ask_optional_domain ORIGIN_DOMAIN "Отдельный origin-домен (можно оставить пустым и использовать IP ноды:443)" "" "origin.example.net"
      ;;
    vk)
      ask_domain ORIGIN_DOMAIN "Origin-домен, A-записью указывающий на VPS-ноду" "" "origin.example.net"
      ask_domain CDN_DOMAIN "Клиентский CDN-домен VK" "" "cdn.example.net"
      ;;
    yandex)
      ask_domain ORIGIN_DOMAIN "Origin-домен ноды с HTTPS-сертификатом" "" "origin.example.net"
      ask_domain CDN_DOMAIN "Клиентский CDN-домен Yandex" "" "cdn.example.net"
      ;;
    beeline)
      ask_domain ORIGIN_DOMAIN "Origin-домен ноды" "" "origin.example.net"
      ask_optional_domain CDN_DOMAIN "Технический домен xxx.a.trbcdn.net (если ресурс ещё не создан — Enter)" "" "abc123.a.trbcdn.net"
      ;;
    timeweb)
      ask_domain CDN_DOMAIN "Клиентский домен Timeweb" "" "cdn.example.net"
      ;;
    selectel)
      ask_optional_domain ORIGIN_DOMAIN "Origin-домен (Enter = IP ноды)" "" "origin.example.net"
      ask_optional_domain CDN_DOMAIN "Технический домен xxxx.selcdn.net (если ещё нет — Enter)" "" "abcd.selcdn.net"
      ;;
  esac
}

rm_profile_config_json(){
  local inbound="$1" method="$2" dns
  if [[ "$method" == yandex ]]; then
    dns='{"queryStrategy":"UseIPv4","servers":[{"address":"8.8.8.8","skipFallback":false}]}'
  else
    dns='{"queryStrategy":"UseIPv4","servers":[{"address":"1.1.1.1","skipFallback":false},{"address":"1.0.0.1","skipFallback":false}]}'
  fi
  jq -nc --argjson inbound "$inbound" --argjson dns "$dns" '{log:{loglevel:"warning"},dns:$dns,inbounds:[$inbound],outbounds:[{tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"BLOCK",protocol:"blackhole"}],routing:{domainStrategy:"IPIfNonMatch",rules:[{type:"field",ip:["geoip:private"],outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}'
}

rm_api_create_profile(){
  local token="$1" name="$2" config="$3" body resp code tmp
  body=$(jq -nc --arg name "$name" --argjson config "$config" '{name:$name,config:$config}')
  tmp=$(mktemp)
  code=$(rm_api_fetch_to_file POST /api/config-profiles "$token" "$tmp" "$body" || true)
  resp=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]] && jq -e '.response.uuid and .response.inbounds[0].uuid' >/dev/null 2>&1 <<<"$resp"; then
    jq -c '{profileUuid:.response.uuid,inboundUuid:.response.inbounds[0].uuid}' <<<"$resp"
    return 0
  fi
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-create-profile.json"
  printf 'HTTP=%s\nprofile_name=%s\nprofile_name_length=%s\n' "$code" "$name" "${#name}" > "$RM_MANAGER_DIR/last-api-error-create-profile-http.txt"
  return 1
}

rm_api_existing_profile(){
  local token="$1" name="$2" profiles uuid r inb
  profiles=$(rm_profiles_json "$token")
  uuid=$(jq -r --arg n "$name" '[.[]? | select(.name==$n) | .uuid][0] // empty' <<<"$profiles")
  [[ -n "$uuid" ]] || return 1
  r=$(rm_api GET "/api/config-profiles/${uuid}/inbounds" "$token" 2>/dev/null || true)
  inb=$(jq -r '.response.inbounds[0].uuid // .response[0].uuid // .response.items[0].uuid // empty' <<<"$r" 2>/dev/null || true)
  if [[ -z "$inb" ]]; then
    r=$(rm_api GET "/api/config-profiles/${uuid}" "$token" 2>/dev/null || true)
    inb=$(jq -r '.response.inbounds[0].uuid // .response.configProfile.inbounds[0].uuid // empty' <<<"$r" 2>/dev/null || true)
  fi
  [[ -n "$inb" ]] || return 1
  jq -nc --arg p "$uuid" --arg i "$inb" '{profileUuid:$p,inboundUuid:$i}'
}

rm_api_assign_node(){
  local token="$1" node_uuid="$2" profile_uuid="$3" inbound_uuid="$4" body resp body_path
  # Remnawave 3.x встречается в двух формах API: PATCH /api/nodes с uuid в body
  # и PATCH /api/nodes/{uuid}. Пробуем обе, ничего не удаляя.
  body=$(jq -nc --arg uuid "$node_uuid" --arg p "$profile_uuid" --arg i "$inbound_uuid" '{uuid:$uuid,configProfile:{activeConfigProfileUuid:$p,activeInbounds:[$i]}}')
  resp=$(rm_api PATCH /api/nodes "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp"; then return 0; fi

  body_path=$(jq -nc --arg p "$profile_uuid" --arg i "$inbound_uuid" '{configProfile:{activeConfigProfileUuid:$p,activeInbounds:[$i]}}')
  resp=$(rm_api PATCH "/api/nodes/${node_uuid}" "$token" "$body_path" 2>/dev/null || true)
  if jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp"; then return 0; fi
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-assign-node.json"
  return 1
}

rm_api_existing_host(){
  local token="$1" profile_uuid="$2" inbound_uuid="$3" address="$4" r
  r=$(rm_hosts_json "$token")
  jq -r --arg p "$profile_uuid" --arg i "$inbound_uuid" --arg a "$address" '
    .[]?
    | select(.address==$a)
    | select((.inbound.configProfileUuid // .configProfileUuid // "")==$p)
    | select((.inbound.configProfileInboundUuid // .configProfileInboundUuid // "")==$i)
    | .uuid' <<<"$r" 2>/dev/null | sed -n '1p'
}

rm_api_create_host(){
  local token="$1" profile_uuid="$2" inbound_uuid="$3" method="$4" address="$5" remark="$6" extra="$7"
  local path alpn fp body resp
  path=$(rm_method_meta "$method" path); alpn=$(rm_method_meta "$method" alpn); fp=$(rm_method_meta "$method" fp)

  # Newer Remnawave uses xhttpExtraParams (lowercase h). Older builds used
  # xHttpExtraParams. Try the current spelling first, then the legacy one.
  body=$(jq -nc --arg p "$profile_uuid" --arg i "$inbound_uuid" --arg remark "$remark" --arg addr "$address" --arg path "$path" --arg alpn "$alpn" --arg fp "$fp" --argjson extra "$extra" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$remark,address:$addr,port:443,path:$path,sni:$addr,host:$addr,alpn:$alpn,fingerprint:$fp,allowInsecure:false,isDisabled:false,securityLayer:"TLS",overrideSniFromAddress:false,xhttpExtraParams:$extra}')
  printf '%s
' "$body" | jq . > "$RM_MANAGER_DIR/last-host-request.json"
  resp=$(rm_api POST /api/hosts "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp"; then jq -r '.response.uuid' <<<"$resp"; return 0; fi

  body=$(jq -nc --arg p "$profile_uuid" --arg i "$inbound_uuid" --arg remark "$remark" --arg addr "$address" --arg path "$path" --arg alpn "$alpn" --arg fp "$fp" --argjson extra "$extra" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$remark,address:$addr,port:443,path:$path,sni:$addr,host:$addr,alpn:$alpn,fingerprint:$fp,allowInsecure:false,isDisabled:false,securityLayer:"TLS",overrideSniFromAddress:false,xHttpExtraParams:$extra}')
  resp=$(rm_api POST /api/hosts "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp"; then jq -r '.response.uuid' <<<"$resp"; return 0; fi

  printf '%s
' "$resp" > "$RM_MANAGER_DIR/last-api-error-create-host.json"
  return 1
}

rm_api_add_to_squad(){
  local token="$1" inbound_uuid="$2" squads count choice sq uuid existing arr body resp
  squads=$(rm_internal_squads_json "$token")
  count=$(jq 'length' <<<"$squads")
  if (( count == 0 )); then
    warn "В панели пока нет Internal Squad."
    ask_yes_no RM_CREATE_SQUAD "Создать отдельный Internal Squad 'PSV1-CDN' и добавить туда новый inbound?" "yes"
    [[ "$RM_CREATE_SQUAD" == yes ]] || return 2
    body=$(jq -nc --arg n "PSV1-CDN" --arg i "$inbound_uuid" '{name:$n,inbounds:[$i]}')
    resp=$(rm_api POST /api/internal-squads "$token" "$body" 2>/dev/null || true)
    if jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp"; then
      ok "Создан Internal Squad PSV1-CDN. Пользователей в него скрипт сам не добавляет — это отдельное право доступа."
      return 0
    fi
    printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-create-squad.json"
    return 1
  fi
  echo
  echo "В какой Internal Squad добавить новый inbound?"
  for ((choice=1; choice<=count; choice++)); do
    sq=$(jq -c ".[${choice}-1]" <<<"$squads")
    printf '  %d — %s\n' "$choice" "$(jq -r '.name // .uuid' <<<"$sq")"
  done
  echo "  0 — назад"
  read -r -p "Выбор [1]: " choice; choice="${choice:-1}"
  [[ "$choice" == 0 ]] && return 2
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=count )) || choice=1
  sq=$(jq -c ".[${choice}-1]" <<<"$squads")
  uuid=$(jq -r '.uuid' <<<"$sq")
  existing=$(jq -c '[.inbounds[]?.uuid]' <<<"$sq")
  arr=$(jq -nc --argjson old "$existing" --arg n "$inbound_uuid" '$old + [$n] | unique')
  body=$(jq -nc --arg uuid "$uuid" --argjson inbounds "$arr" '{uuid:$uuid,inbounds:$inbounds}')
  resp=$(rm_api PATCH /api/internal-squads "$token" "$body" 2>/dev/null || true)
  jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp" && return 0
  # Более новые контракты используют UUID в URL.
  body=$(jq -nc --argjson inbounds "$arr" '{inbounds:$inbounds}')
  resp=$(rm_api PATCH "/api/internal-squads/${uuid}" "$token" "$body" 2>/dev/null || true)
  jq -e '.response.uuid' >/dev/null 2>&1 <<<"$resp" && return 0
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-squad.json"
  return 1
}


provider_dns_hint(){
  local record="$1"
  if [[ "${USE_CLOUDFLARE:-yes}" == yes ]]; then
    user_prepare "DNS: ${record} в Cloudflare с Proxy status = DNS only."
  else
    user_prepare "DNS: ${record} у текущего DNS-провайдера; проксирование/ускорение DNS-провайдера выключить."
  fi
}

show_provider_preflight(){
  local method="$1" node_ip="${2:-IP_НОДЫ}"
  [[ "$method" == none || -z "$method" ]] && return 0
  ui_title "ЧТО НУЖНО ПОДГОТОВИТЬ ПОЛЬЗОВАТЕЛЮ — $(method_title "$method")"
  echo -e "${C_MAGENTA}Скрипт автоматизирует сервер и Remnawave. Кабинет CDN/регистратора без API-токена провайдера он не может нажимать за тебя.${C_RESET}"
  echo
  if [[ -n "${ORIGIN_DOMAIN:-}" ]]; then
    provider_dns_hint "A ${ORIGIN_DOMAIN} -> ${node_ip}"
  fi
  case "$method" in
    vk)
      user_prepare "VK Cloud -> CDN -> создать ресурс: origin ${ORIGIN_DOMAIN}:80 по HTTP."
      user_prepare "Персональный домен: ${CDN_DOMAIN}; Host пересылать; Let's Encrypt; cache OFF; gzip OFF; методы GET/HEAD/OPTIONS."
      user_prepare "После создания VK выдаст CNAME. Создай CNAME для ${CDN_DOMAIN} -> выданный VK адрес (DNS only)."
      ;;
    yandex)
      user_prepare "Yandex Certificate Manager: выпустить Let's Encrypt для ${CDN_DOMAIN} через DNS validation."
      user_prepare "CNAME _acme-challenge, который даст Yandex, добавить в DNS и НЕ удалять после выпуска."
      user_prepare "CDN resource: origin=${ORIGIN_DOMAIN}, HTTPS, ручной SNI=${ORIGIN_DOMAIN}, Host=${ORIGIN_DOMAIN}, домен раздачи=${CDN_DOMAIN}."
      user_prepare "Cache CDN/browser OFF; query НЕ игнорировать; compression OFF; verify origin certificate OFF."
      ;;
    beeline)
      user_prepare "CDNvideo/Beeline: создать ресурс 'Статика' с origin ${ORIGIN_DOMAIN}:443, HTTPS ON, verify certificate OFF, SNI=${ORIGIN_DOMAIN}."
      user_prepare "Host пересылать; cache OFF; query учитывать; HTTP/2 ON; rewrite /static/getFile/video/segment.ts/ -> /static/getFile/video/segment.ts."
      user_prepare "Скопируй технический домен вида xxx.a.trbcdn.net — скрипт попросит его перед созданием Host."
      ;;
    timeweb)
      user_prepare "Timeweb Cloud -> CDN: источник строго ${node_ip}:80, вкладка IP-адрес; HTTPS к источнику OFF."
      user_prepare "Cache OFF; 'Игнорировать параметры запроса' OFF; добавить домен ${CDN_DOMAIN}."
      user_prepare "После выдачи xxx.cdn.twcstorage.ru создай CNAME ${CDN_DOMAIN} -> техдомен (DNS only). После статуса 'Активен' выпусти LE."
      ;;
    selectel)
      user_prepare "Selectel -> CDN: создать ресурс, тип оптимизации 'Статика'; origin=${ORIGIN_DOMAIN:-$node_ip}."
      user_prepare "Cache OFF; gzip OFF; query НЕ игнорировать; verify origin certificate OFF; разрешить POST."
      user_prepare "Таймауты origin: connect=30, send=9999, receive=9999."
      user_prepare "После ACTIVE скопируй технический домен xxxx.selcdn.net — скрипт попросит его перед созданием Host."
      ;;
    turboflare)
      user_prepare "TurboFlare -> Сайты -> ${CDN_DOMAIN}: Address/Origin = ${node_ip}:443, HTTPS к источнику ON, stale cache OFF."
      user_prepare "До переключения старого рабочего ресурса сначала проверь direct origin на новой ноде: ожидается HTTP 400."
      user_prepare "Финальные NS домена ${CDN_DOMAIN}: ns1-c.trbcdn.net / ns2-c.trbcdn.net / ns3-c.trbcdn.net."
      user_prepare "После делегирования ${CDN_DOMAIN} должен резолвиться в edge TurboFlare, НЕ в ${node_ip}."
      ;;
  esac
  echo
  echo -e "${C_CYAN}Дальше скрипт сам создаст/свяжет то, что доступно через API Remnawave. Незавершённые ручные пункты будут повторены в конце.${C_RESET}"
}

print_manual_file_colored(){
  local f="$1" line
  [[ -s "$f" ]] || return 0
  ui_title "ОСТАЛОСЬ СДЕЛАТЬ ВРУЧНУЮ"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      echo
    elif [[ "$line" == *"===="* || "$line" == *"— что осталось"* || "$line" == *"— настройки"* ]]; then
      echo -e "${C_BOLD}${C_CYAN}${line}${C_RESET}"
    elif [[ "$line" == "Важно:"* || "$line" == "ВАЖНО:"* ]]; then
      echo -e "${C_RED}${line}${C_RESET}"
    elif [[ "$line" == "После"* || "$line" == "Ожидаемый"* ]]; then
      check_do "$line"
    else
      manual_do "$line"
    fi
  done < "$f"
}

rm_manager_provider_steps(){
  local method="$1" node_ip="$2" f="$3"
  {
    echo "$(method_title "$method") — что осталось сделать у CDN-провайдера"
    echo "=============================================================="
    if [[ "${USE_CLOUDFLARE:-yes}" == yes ]]; then
      echo "DNS: используется Cloudflare. A/CNAME из этой инструкции создавай как DNS only."
    else
      echo "DNS: Cloudflare отключён. Те же A/CNAME создай у текущего DNS-провайдера без его proxy/CDN-ускорения."
    fi
    echo
    case "$method" in
      turboflare)
        echo "TurboFlare → Сайты → ${CDN_DOMAIN} → Редактирование:"
        echo "  Адрес: ${node_ip}:443"
        echo "  HTTPS к источнику: ВКЛ"
        echo "  Устаревший кэш при недоступности источника: ВЫКЛ"
        echo "  Кэш XHTTP: ВЫКЛ; query-параметры учитывать."
        echo "  NS у регистратора: ns1-c.trbcdn.net / ns2-c.trbcdn.net / ns3-c.trbcdn.net"
        echo "Важно: ${CDN_DOMAIN} после делегирования должен вести на edge CDN, а не на ${node_ip}."
        ;;
      vk)
        echo "Источник: ${ORIGIN_DOMAIN}:80 по HTTP. CDN-домен: ${CDN_DOMAIN}. Host пересылать."
        echo "Кэш выключить, query учитывать, gzip выключить; затем CNAME CDN-домена на адрес VK."
        ;;
      yandex)
        echo "Источник: ${ORIGIN_DOMAIN} по HTTPS; ручной SNI/Host=${ORIGIN_DOMAIN}; CDN-домен=${CDN_DOMAIN}."
        echo "Кэш CDN/браузера выключить, query не игнорировать, compression выключить, verify origin выключить."
        ;;
      beeline)
        echo "Источник: ${ORIGIN_DOMAIN}:443, HTTPS ВКЛ, SNI=${ORIGIN_DOMAIN}, cache OFF, query учитывать."
        echo "Rewrite на CDN: /static/getFile/video/segment.ts/ -> /static/getFile/video/segment.ts; HTTP2 ВКЛ."
        echo "После активации получишь xxx.a.trbcdn.net; если сейчас домен был пустой — снова запусти менеджер и создай host."
        ;;
      timeweb)
        echo "Источник строго ${node_ip}:80; HTTPS к источнику ВЫКЛ; query не игнорировать; cache OFF."
        echo "Клиентский домен: ${CDN_DOMAIN}."
        ;;
      selectel)
        echo "Источник: ${ORIGIN_DOMAIN:-$node_ip}; cache/gzip OFF; query не игнорировать; verify origin OFF; разрешить POST."
        echo "Таймауты: connect=30, send=9999, receive=9999. После активации получишь xxxx.selcdn.net."
        ;;
    esac
    echo
    echo "После активации CDN: curl -sk https://${CDN_DOMAIN:-'<техдомен>'}$(rm_method_meta "$method" path) -o /dev/null -w '%{http_code}\\n'"
    echo "Ожидаемый код после активного inbound: 400."
  } > "$f"
  chmod 600 "$f"
}


rm_subscription_templates_json(){
  local token="$1" r
  r=$(rm_api GET /api/subscription-templates "$token" 2>/dev/null || true)
  jq -c '
    (.response.templates // .response.items // .templates // .response // [])
    | if type=="array" then . else [] end
  ' <<<"$r" 2>/dev/null || echo '[]'
}

rm_external_squads_json(){
  local token="$1" r
  r=$(rm_api GET /api/external-squads "$token" 2>/dev/null || true)
  jq -c '
    (.response.externalSquads // .response.external_squads // .response.items // .externalSquads // .response // [])
    | if type=="array" then . else [] end
  ' <<<"$r" 2>/dev/null || echo '[]'
}

rm_default_xray_subscription_json(){
  jq -nc '{
    remnawave:{addVirtualHostAsOutbound:true},
    dns:{servers:["1.1.1.1","1.0.0.1"]},
    routing:{rules:[
      {protocol:["bittorrent"],outboundTag:"direct"},
      {ip:["geoip:private"],outboundTag:"direct"},
      {domain:["geosite:private"],outboundTag:"direct"}
    ],domainStrategy:"IPIfNonMatch"},
    inbounds:[
      {tag:"socks",port:10808,listen:"127.0.0.1",protocol:"socks",settings:{udp:true},sniffing:{enabled:true,destOverride:["http","tls","quic"]}},
      {tag:"http",port:10809,listen:"127.0.0.1",protocol:"http",sniffing:{enabled:true,destOverride:["http","tls","quic"]}}
    ],
    outbounds:[
      {tag:"direct",protocol:"freedom"},
      {tag:"block",protocol:"blackhole"}
    ]
  }'
}

rm_api_get_template_json(){
  local token="$1" uuid="$2" r
  r=$(rm_api GET "/api/subscription-templates/${uuid}" "$token" 2>/dev/null || true)
  jq -c '.response.templateJson // .response.template.templateJson // .templateJson // empty' <<<"$r" 2>/dev/null || true
}

rm_api_create_or_reuse_xray_template(){
  local token="$1" name="$2" templates existing_uuid default_uuid source_json body resp uuid
  templates=$(rm_subscription_templates_json "$token")
  existing_uuid=$(jq -r --arg n "$name" '[.[]? | select((.name // "")==$n and ((.templateType // .template_type // "")=="XRAY_JSON")) | .uuid][0] // empty' <<<"$templates")

  # Take current Default as a base when possible, but make the dedicated template
  # actually use the Host that receives it: Remnawave >=2.6.3 understands
  # remnawave.addVirtualHostAsOutbound and injects that Host as outbound "proxy".
  default_uuid=$(jq -r '[.[]? | select(((.templateType // .template_type // "")=="XRAY_JSON") and ((.name // "")|test("^Default";"i"))) | .uuid][0] // empty' <<<"$templates")
  source_json=""
  [[ -n "$default_uuid" ]] && source_json=$(rm_api_get_template_json "$token" "$default_uuid")
  [[ -n "$source_json" && "$source_json" != null ]] || source_json=$(rm_default_xray_subscription_json)
  source_json=$(jq -c '.remnawave = ((.remnawave // {}) + {addVirtualHostAsOutbound:true})' <<<"$source_json" 2>/dev/null || rm_default_xray_subscription_json)

  if [[ -n "$existing_uuid" ]]; then
    uuid="$existing_uuid"
  else
    body=$(jq -nc --arg n "$name" '{name:$n,templateType:"XRAY_JSON"}')
    resp=$(rm_api POST /api/subscription-templates "$token" "$body" 2>/dev/null || true)
    uuid=$(jq -r '.response.uuid // .response.template.uuid // .uuid // empty' <<<"$resp" 2>/dev/null || true)
    if [[ -z "$uuid" ]]; then
      printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-create-xray-template.json"
      return 1
    fi
  fi

  body=$(jq -nc --arg u "$uuid" --arg n "$name" --argjson j "$source_json" '{uuid:$u,name:$n,templateJson:$j}')
  resp=$(rm_api PATCH /api/subscription-templates "$token" "$body" 2>/dev/null || true)
  if ! jq -e '.response.uuid // .response.template.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then
    printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-update-xray-template.json"
    return 2
  fi
  printf '%s' "$uuid"
}

rm_api_bind_xray_template_to_host(){
  local token="$1" host_uuid="$2" template_uuid="$3" body resp
  body=$(jq -nc --arg u "$host_uuid" --arg t "$template_uuid" '{uuid:$u,xrayJsonTemplateUuid:$t}')
  resp=$(rm_api PATCH /api/hosts "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then
    return 0
  fi
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-bind-host-xray-template.json"
  return 1
}

rm_api_host_xray_template_uuid(){
  local token="$1" host_uuid="$2" r
  r=$(rm_api GET "/api/hosts/${host_uuid}" "$token" 2>/dev/null || true)
  jq -r '.response.xrayJsonTemplateUuid // .xrayJsonTemplateUuid // empty' <<<"$r" 2>/dev/null || true
}

rm_api_reorder_xray_templates(){
  local token="$1" preferred_uuid="$2" templates body resp
  templates=$(rm_subscription_templates_json "$token")
  [[ $(jq 'length' <<<"$templates") -gt 1 ]] || return 0
  body=$(jq -nc --arg p "$preferred_uuid" --argjson t "$templates" '
    def isdefault: (((.templateType // .template_type // "")=="XRAY_JSON") and ((.name // "")|test("^Default";"i")));
    ($t
      | sort_by(if .uuid==$p then 0 elif isdefault then 2 else 1 end)
      | to_entries
      | map({uuid:.value.uuid,viewPosition:(.key+1)})
    ) as $items
    | {items:$items}')
  resp=$(rm_api POST /api/subscription-templates/actions/reorder "$token" "$body" 2>/dev/null || true)
  jq -e '.response // .templates // .isSuccess // .success // .items' >/dev/null 2>&1 <<<"$resp"
}

rm_api_delete_default_xray_templates(){
  local token="$1" keep_uuid="$2" templates uuids u resp okall=yes
  templates=$(rm_subscription_templates_json "$token")
  uuids=$(jq -r --arg keep "$keep_uuid" '.[]? | select(.uuid!=$keep) | select(((.templateType // .template_type // "")=="XRAY_JSON") and ((.name // "")|test("^Default";"i"))) | .uuid' <<<"$templates")
  [[ -n "$uuids" ]] || return 0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    resp=$(rm_api DELETE "/api/subscription-templates/${u}" "$token" 2>/dev/null || true)
    jq -e '.response.isDeleted // .isDeleted // .response // false' >/dev/null 2>&1 <<<"$resp" || okall=no
  done <<<"$uuids"
  [[ "$okall" == yes ]]
}

rm_api_create_or_update_external_squad(){
  local token="$1" name="$2" template_uuid="$3" squads squad uuid detail old merged body resp
  squads=$(rm_external_squads_json "$token")
  squad=$(jq -c --arg n "$name" '[.[]? | select((.name // "")==$n)][0] // empty' <<<"$squads")
  uuid=$(jq -r '.uuid // empty' <<<"$squad" 2>/dev/null || true)
  if [[ -z "$uuid" ]]; then
    body=$(jq -nc --arg n "$name" '{name:$n}')
    resp=$(rm_api POST /api/external-squads "$token" "$body" 2>/dev/null || true)
    uuid=$(jq -r '.response.uuid // .uuid // empty' <<<"$resp" 2>/dev/null || true)
    [[ -n "$uuid" ]] || { printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-create-external-squad.json"; return 1; }
    squad=$(jq -c '.response // .' <<<"$resp")
  fi

  detail=$(rm_api GET "/api/external-squads/${uuid}" "$token" 2>/dev/null || true)
  old=$(jq -c '.response.templates // .templates // []' <<<"$detail" 2>/dev/null || echo '[]')
  [[ "$old" == "null" || -z "$old" ]] && old='[]'
  merged=$(jq -nc --argjson old "$old" --arg t "$template_uuid" '
    ($old | map(select((.templateType // .template_type // "")!="XRAY_JSON")))
    + [{templateUuid:$t,templateType:"XRAY_JSON"}]')
  body=$(jq -nc --arg u "$uuid" --arg n "$name" --argjson templates "$merged" '{uuid:$u,name:$n,templates:$templates}')
  resp=$(rm_api PATCH /api/external-squads "$token" "$body" 2>/dev/null || true)
  if ! jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then
    printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-update-external-squad.json"
    return 2
  fi
  printf '%s' "$uuid"
}

rm_api_add_external_squad_all_users(){
  local token="$1" uuid="$2" resp
  resp=$(rm_api POST "/api/external-squads/${uuid}/bulk-actions/add-users" "$token" '{}' 2>/dev/null || true)
  jq -e '.response.eventSent // .eventSent // .response // false' >/dev/null 2>&1 <<<"$resp"
}

rm_manage_xray_subscription_layer(){
  local token="$1" method="$2" node_name="$3" run_dir="$4" host_uuid="$5"
  local template_name squad_name template_uuid="" squad_uuid="" trc=0 current_host_template="" bind_ok=yes
  RM_XRAY_TEMPLATE_OK=no
  RM_XRAY_TEMPLATE_UUID=""
  RM_EXTERNAL_SQUAD_OK=no
  RM_EXTERNAL_SQUAD_UUID=""
  RM_DEFAULT_MOVED=no
  RM_DEFAULT_DELETED=no
  RM_EXTERNAL_USERS_ALL=no
  RM_HOST_XRAY_TEMPLATE_OK=no

  echo
  ui_title "Xray JSON ПОДПИСКИ"
  echo "Это клиентский шаблон из раздела Подписка -> Xray JSON, НЕ серверный Config Profile."
  ask_yes_no RM_CREATE_XRAY_TEMPLATE "Создать отдельный Xray JSON шаблон для $(method_title "$method") и убрать Default вниз списка?" "yes"
  [[ "$RM_CREATE_XRAY_TEMPLATE" == yes ]] || { manual_do "Xray JSON оставлен как есть; будет использоваться текущая логика Default/правил панели."; return 0; }

  template_name="PSV1 $(method_title "$method")"
  template_name=$(printf '%s' "$template_name" | sed 's/[^A-Za-z0-9 _-]/-/g')
  rm_default_xray_subscription_json | jq . > "$run_dir/xray-subscription-template.json"
  if template_uuid=$(rm_api_create_or_reuse_xray_template "$token" "$template_name"); then
    trc=0
    RM_XRAY_TEMPLATE_OK=yes
    RM_XRAY_TEMPLATE_UUID="$template_uuid"
    auto_done "Xray JSON шаблон '$template_name' создан/найден и готов."
    # Save the exact effective template for the manual fallback/audit trail.
    rm_api_get_template_json "$token" "$template_uuid" | jq . > "$run_dir/xray-subscription-template.json" 2>/dev/null || rm_default_xray_subscription_json | jq . > "$run_dir/xray-subscription-template.json"
    current_host_template=$(rm_api_host_xray_template_uuid "$token" "$host_uuid")
    bind_ok=yes
    if [[ -n "$current_host_template" && "$current_host_template" != "$template_uuid" ]]; then
      danger "У Host уже назначен другой Xray JSON template UUID=$current_host_template."
      ask_yes_no RM_REPLACE_HOST_XRAY_TEMPLATE "Заменить Xray JSON template именно у этого Host на '$template_name'?" "no"
      [[ "$RM_REPLACE_HOST_XRAY_TEMPLATE" == yes ]] || bind_ok=no
    fi
    if [[ "$bind_ok" == yes ]] && rm_api_bind_xray_template_to_host "$token" "$host_uuid" "$template_uuid"; then
      RM_HOST_XRAY_TEMPLATE_OK=yes
      auto_done "Xray JSON шаблон назначен Host UUID=$host_uuid."
    elif [[ "$bind_ok" == no ]]; then
      warn "Xray JSON template у Host не менялся по твоему выбору. В конце будет ручной пункт."
    else
      warn "Шаблон создан, но API не назначил его Host. В конце будет точный ручной пункт: Hosts -> нужный Host -> Xray JSON Template."
    fi
  else
    trc=$?
    if [[ $trc -eq 2 ]]; then
      warn "Шаблон создан, но API не заполнил JSON-контент. В конце будет ручной пункт."
    else
      warn "Xray JSON шаблон через API не создан. Основной CDN Host от этого не удаляется."
    fi
    return 0
  fi

  if rm_api_reorder_xray_templates "$token" "$template_uuid"; then
    RM_DEFAULT_MOVED=yes
    auto_done "Новый Xray JSON поднят вверх, Default перемещён в конец списка."
  else
    warn "API reorder шаблонов не сработал. Это косметика: в конце будет ручной пункт перетащить Default вниз."
  fi

  ask_yes_no RM_CREATE_EXTERNAL_SQUAD "Создать отдельный External Squad и привязать к нему этот Xray JSON шаблон?" "yes"
  if [[ "$RM_CREATE_EXTERNAL_SQUAD" == yes ]]; then
    squad_name="PSV1 $(method_title "$method")"
    squad_name=$(printf '%s' "$squad_name" | sed 's/[^A-Za-z0-9 _-]/-/g')
    squad_name="${squad_name:0:30}"
    if squad_uuid=$(rm_api_create_or_update_external_squad "$token" "$squad_name" "$template_uuid"); then
      RM_EXTERNAL_SQUAD_OK=yes
      RM_EXTERNAL_SQUAD_UUID="$squad_uuid"
      auto_done "External Squad '$squad_name' создан/найден и привязан к Xray JSON шаблону."
      ask_yes_no RM_EXTERNAL_ALL_USERS "Назначить этот External Squad ВСЕМ существующим пользователям? Это может заменить их текущую внешнюю группу" "no"
      if [[ "$RM_EXTERNAL_ALL_USERS" == yes ]]; then
        if rm_api_add_external_squad_all_users "$token" "$squad_uuid"; then
          auto_done "External Squad назначен всем пользователям."
          RM_EXTERNAL_USERS_ALL=yes
        else
          warn "Массовое назначение не прошло. Добавь нужных пользователей в External Squad вручную."
        fi
      fi
    else
      warn "External Squad автоматически не настроен. В конце будет точный ручной пункт."
    fi
  fi

  echo
  danger "Удаление Default Xray JSON может сломать пользователей, которые НЕ состоят в созданном External Squad и не попадают под отдельное Response Rule."
  ask_yes_no RM_DELETE_DEFAULT_XRAY "Удалить Default Xray JSON сейчас? (обычно лучше оставить как запасной)" "no"
  if [[ "$RM_DELETE_DEFAULT_XRAY" == yes ]]; then
    if [[ "$RM_EXTERNAL_SQUAD_OK" == yes ]] && rm_api_delete_default_xray_templates "$token" "$template_uuid"; then
      RM_DEFAULT_DELETED=yes
      auto_done "Default Xray JSON удалён по явному подтверждению."
    else
      warn "Default НЕ удалён: сначала должен быть рабочий отдельный шаблон + External Squad."
    fi
  fi

  {
    echo "template_name=$template_name"
    echo "template_uuid=${RM_XRAY_TEMPLATE_UUID}"
    echo "template_ready=${RM_XRAY_TEMPLATE_OK}"
    echo "host_template_bound=${RM_HOST_XRAY_TEMPLATE_OK}"
    echo "default_moved=${RM_DEFAULT_MOVED}"
    echo "default_deleted=${RM_DEFAULT_DELETED}"
    echo "external_squad_uuid=${RM_EXTERNAL_SQUAD_UUID}"
    echo "external_squad_ready=${RM_EXTERNAL_SQUAD_OK}"
    echo "all_users_assigned=${RM_EXTERNAL_USERS_ALL}"
  } > "$run_dir/subscription-layer.txt"
}


rm_api_profile_doc(){
  local token="$1" uuid="$2" r
  r=$(rm_api GET "/api/config-profiles/${uuid}" "$token" 2>/dev/null || true)
  jq -c '.response.configProfile // .response // .' <<<"$r" 2>/dev/null || return 1
}

rm_api_profile_inbounds(){
  local token="$1" uuid="$2" r
  r=$(rm_api GET "/api/config-profiles/${uuid}/inbounds" "$token" 2>/dev/null || true)
  jq -c '(.response.inbounds // .response.items // .response // .inbounds // []) | if type=="array" then . else [] end' <<<"$r" 2>/dev/null || echo '[]'
}

rm_api_patch_profile_config(){
  local token="$1" uuid="$2" config="$3" body resp tmp code
  body=$(jq -nc --arg u "$uuid" --argjson c "$config" '{uuid:$u,config:$c}')
  tmp=$(mktemp)
  code=$(rm_api_fetch_to_file PATCH /api/config-profiles "$token" "$tmp" "$body" || true)
  resp=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]] && jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then
    return 0
  fi
  printf 'HTTP=%s\n' "$code" > "$RM_MANAGER_DIR/last-api-error-cascade-profile-http.txt"
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-cascade-profile.json"
  return 1
}

rm_api_add_active_inbound_preserve(){
  local token="$1" node_json="$2" profile_uuid="$3" inbound_uuid="$4" node_uuid profile_inbounds arr body resp body_path
  node_uuid=$(jq -r '.uuid' <<<"$node_json")
  # PATCH config-profile can return/reforge inbound UUIDs. Preserve old active
  # inbounds primarily by tag, then by still-existing UUID, and append BRIDGE_IN.
  profile_inbounds=$(rm_api_profile_inbounds "$token" "$profile_uuid")
  arr=$(jq -nc --argjson node "$node_json" --argjson current "$profile_inbounds" --arg bridge "$inbound_uuid" '
    ($node.configProfile.activeInbounds // []) as $old
    | ([$old[]? | select(type=="object") | .tag // empty]) as $tags
    | ([$old[]? | if type=="string" then . else (.uuid // empty) end | select(length>0)]) as $ids
    | ([ $current[]? | select((.tag // "") as $t | ($tags | index($t)) != null) | .uuid ]) as $bytag
    | ([ $current[]? | select((.uuid // "") as $u | ($ids | index($u)) != null) | .uuid ]) as $byid
    | ($bytag + $byid + [$bridge] | map(select(length>0)) | unique)
  ')
  body=$(jq -nc --arg u "$node_uuid" --arg p "$profile_uuid" --argjson a "$arr" '{uuid:$u,configProfile:{activeConfigProfileUuid:$p,activeInbounds:$a}}')
  resp=$(rm_api PATCH /api/nodes "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then return 0; fi
  body_path=$(jq -nc --arg p "$profile_uuid" --argjson a "$arr" '{configProfile:{activeConfigProfileUuid:$p,activeInbounds:$a}}')
  resp=$(rm_api PATCH "/api/nodes/${node_uuid}" "$token" "$body_path" 2>/dev/null || true)
  if jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then return 0; fi
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-cascade-node.json"
  return 1
}
rm_cascade_bridge_inbound_json(){
  local tag="$1"
  jq -nc --arg tag "$tag" '{tag:$tag,port:8888,listen:"0.0.0.0",protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",security:"none"}}'
}

rm_api_ensure_bridge_in_active_profile(){
  local token="$1" node_json="$2" bridge_tag="$3" run_dir="$4"
  local profile_uuid doc config existing bridge inbound_uuid inbounds patched
  profile_uuid=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$node_json")
  if [[ -z "$profile_uuid" || "$profile_uuid" == "00000000-0000-0000-0000-000000000000" ]]; then
    return 4
  fi
  doc=$(rm_api_profile_doc "$token" "$profile_uuid") || return 1
  printf '%s\n' "$doc" | jq . > "$run_dir/exit-profile-before.json" 2>/dev/null || true
  config=$(jq -c '.config // empty' <<<"$doc")
  [[ -n "$config" && "$config" != null ]] || return 1
  existing=$(jq -c '[.inbounds[]? | select((.port==8888) or ((.tag//"")|startswith("BRIDGE_IN")))][0] // empty' <<<"$config")
  if [[ -n "$existing" ]]; then
    bridge_tag=$(jq -r '.tag' <<<"$existing")
  else
    bridge=$(rm_cascade_bridge_inbound_json "$bridge_tag")
    patched=$(jq -nc --argjson c "$config" --argjson b "$bridge" '$c | .inbounds=((.inbounds//[])+[$b])')
    printf '%s\n' "$patched" | jq . > "$run_dir/exit-profile-after.json"
    rm_api_patch_profile_config "$token" "$profile_uuid" "$patched" || return 2
  fi
  inbounds=$(rm_api_profile_inbounds "$token" "$profile_uuid")
  inbound_uuid=$(jq -r --arg t "$bridge_tag" '[.[]? | select((.tag==$t) or (.port==8888)) | .uuid][0] // empty' <<<"$inbounds")
  [[ -n "$inbound_uuid" ]] || return 3
  jq -nc --arg p "$profile_uuid" --arg i "$inbound_uuid" --arg t "$bridge_tag" '{profileUuid:$p,inboundUuid:$i,tag:$t}'
}

rm_api_create_bridge_only_profile(){
  local token="$1" node_uuid="$2" bridge_tag="$3" name="$4" bridge config ids
  bridge=$(rm_cascade_bridge_inbound_json "$bridge_tag")
  config=$(jq -nc --argjson b "$bridge" '{log:{loglevel:"warning"},inbounds:[$b],outbounds:[{tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"BLOCK",protocol:"blackhole"}],routing:{domainStrategy:"IPIfNonMatch",rules:[{type:"field",ip:["geoip:private"],outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}')
  ids=$(rm_api_create_profile "$token" "$name" "$config") || return 1
  printf '%s' "$ids"
}

rm_cascade_relay_config_json(){
  local method="$1" tag="$2" exits_json="$3" strategy="${4:-roundRobin}" inbound
  inbound=$(rm_method_inbound_json "$method" "$tag")
  inbound=$(jq -c --arg t "$tag" '.tag=$t | .port=7443 | .listen="127.0.0.1"' <<<"$inbound")
  jq -nc --argjson inb "$inbound" --argjson exits "$exits_json" --arg strategy "$strategy" '
    ($exits|length) as $n
    | ($n == 1) as $single
    | ($exits | map({
        tag:(if $single then "VLESS_EXIT" else ("VLESS_EXIT_" + .suffix) end),
        protocol:"vless",
        settings:{vnext:[{address:.ip,port:8888,users:[{id:.bridgeUuid,encryption:"none"}]}]},
        streamSettings:{network:"tcp",security:"none",sockopt:{tcpKeepAliveInterval:30,tcpNoDelay:true}},
        mux:{enabled:true,concurrency:8,xudpConcurrency:16,xudpProxyUDP443:"reject"}
      })) as $proxyOutbounds
    | (if $single
       then {type:"field",ip:["149.154.160.0/20","91.108.4.0/22","91.108.8.0/22","91.108.12.0/22","91.108.16.0/22","91.108.20.0/22","91.108.56.0/22"],outboundTag:"VLESS_EXIT"}
       else {type:"field",ip:["149.154.160.0/20","91.108.4.0/22","91.108.8.0/22","91.108.12.0/22","91.108.16.0/22","91.108.20.0/22","91.108.56.0/22"],balancerTag:"EXIT_POOL"}
       end) as $telegramIpRule
    | (if $single
       then {type:"field",domain:["domain:telegram.org","domain:t.me","domain:telegra.ph"],outboundTag:"VLESS_EXIT"}
       else {type:"field",domain:["domain:telegram.org","domain:t.me","domain:telegra.ph"],balancerTag:"EXIT_POOL"}
       end) as $telegramDomainRule
    | (if $single
       then {type:"field",network:"tcp,udp",outboundTag:"VLESS_EXIT"}
       else {type:"field",network:"tcp,udp",balancerTag:"EXIT_POOL"}
       end) as $catchAll
    | {
        log:{loglevel:"warning"},
        inbounds:[$inb],
        outbounds:($proxyOutbounds + [
          {tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},
          {tag:"BLOCK",protocol:"blackhole"}
        ]),
        routing:(
          {domainStrategy:"IPIfNonMatch",rules:[
            {type:"field",ip:["geoip:private"],outboundTag:"BLOCK"},
            {type:"field",domain:["geosite:private"],outboundTag:"BLOCK"},
            {type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"},
            {type:"field",ip:["1.1.1.1","1.0.0.1","8.8.8.8","8.8.4.4"],outboundTag:"DIRECT"},
            $telegramIpRule,
            $telegramDomainRule,
            {type:"field",ip:["geoip:ru"],outboundTag:"DIRECT"},
            {type:"field",domain:["geosite:category-ru"],outboundTag:"DIRECT"},
            $catchAll
          ]}
          + (if $single then {} else {balancers:[{tag:"EXIT_POOL",selector:["VLESS_EXIT_"],strategy:{type:$strategy}}]} end)
        )
      }
  '
}

rm_api_ensure_named_squad(){
  local token="$1" name="$2" inbound_a="$3" inbound_b="${4:-}" squads sq uuid old arr body resp
  squads=$(rm_internal_squads_json "$token")
  sq=$(jq -c --arg n "$name" '[.[]? | select(.name==$n)][0] // empty' <<<"$squads")
  uuid=$(jq -r '.uuid // empty' <<<"$sq" 2>/dev/null || true)
  if [[ -z "$uuid" ]]; then
    arr=$(jq -nc --arg a "$inbound_a" --arg b "$inbound_b" '[ $a, $b ] | map(select(length>0)) | unique')
    body=$(jq -nc --arg n "$name" --argjson a "$arr" '{name:$n,inbounds:$a}')
    resp=$(rm_api POST /api/internal-squads "$token" "$body" 2>/dev/null || true)
    uuid=$(jq -r '.response.uuid // .uuid // empty' <<<"$resp" 2>/dev/null || true)
    [[ -n "$uuid" ]] || { printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-cascade-squad.json"; return 1; }
    printf '%s' "$uuid"; return 0
  fi
  old=$(jq -c '[.inbounds[]? | if type=="string" then . else .uuid end | select(.!=null and .!="")]' <<<"$sq" 2>/dev/null || echo '[]')
  arr=$(jq -nc --argjson o "$old" --arg a "$inbound_a" --arg b "$inbound_b" '$o + [$a,$b] | map(select(length>0)) | unique')
  body=$(jq -nc --arg u "$uuid" --arg n "$name" --argjson a "$arr" '{uuid:$u,name:$n,inbounds:$a}')
  resp=$(rm_api PATCH /api/internal-squads "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then printf '%s' "$uuid"; return 0; fi
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-cascade-squad.json"
  return 1
}

rm_api_ensure_bridge_user(){
  local token="$1" username="$2" desired_uuid="$3" squad_uuid="$4" r user user_uuid vless old arr body resp expire
  r=$(rm_api GET "/api/users/by-username/${username}" "$token" 2>/dev/null || true)
  user=$(jq -c '.response.user // .response // empty' <<<"$r" 2>/dev/null || true)
  user_uuid=$(jq -r '.uuid // empty' <<<"$user" 2>/dev/null || true)
  if [[ -n "$user_uuid" ]]; then
    vless=$(jq -r '.vlessUuid // .vless_uuid // empty' <<<"$user")
    [[ -n "$vless" ]] || vless="$desired_uuid"
    old=$(jq -c '[.activeInternalSquads[]? | if type=="string" then . else .uuid end | select(.!=null and .!="")]' <<<"$user" 2>/dev/null || echo '[]')
    arr=$(jq -nc --argjson o "$old" --arg s "$squad_uuid" '$o + [$s] | unique')
    body=$(jq -nc --arg u "$user_uuid" --argjson a "$arr" '{uuid:$u,activeInternalSquads:$a}')
    resp=$(rm_api PATCH /api/users "$token" "$body" 2>/dev/null || true)
    if jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then printf '%s' "$vless"; return 0; fi
    printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-cascade-user.json"
    return 2
  fi
  expire=$(date -u -d '+10 years' '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  body=$(jq -nc --arg n "$username" --arg e "$expire" --arg v "$desired_uuid" --arg s "$squad_uuid" '{username:$n,expireAt:$e,trafficLimitBytes:0,trafficLimitStrategy:"NO_RESET",vlessUuid:$v,activeInternalSquads:[$s]}')
  resp=$(rm_api POST /api/users "$token" "$body" 2>/dev/null || true)
  if jq -e '.response.uuid // .uuid' >/dev/null 2>&1 <<<"$resp"; then printf '%s' "$desired_uuid"; return 0; fi
  printf '%s\n' "$resp" > "$RM_MANAGER_DIR/last-api-error-cascade-user.json"
  return 1
}

run_remna_cascade_manager(){
  local token nodes count relay relay_uuid relay_name relay_ip method pool_suffix relay_tag relay_config relay_profile_name relay_ids relay_profile_uuid relay_inbound_uuid relay_active squad_uuid host_uuid="" extra run_dir profile_doc existing_cfg desired_hash current_hash update_profile=no
  local exit_mode exit_mode_choice exits exit_count strategy_choice strategy first_exit first_exit_uuid first_exit_ip exit_keys exit_records='[]'
  local panel_public_ip="" relay_addr_ip="" relay_on_panel=no relay_proxy_note=""
  local i e e_uuid e_name e_ip e_suffix bridge_tag bridge_uuid bridge_info exit_profile_uuid bridge_inbound_uuid exit_profile_name exit_dir record user_name b inbs

  echo
  ui_title "КАСКАД REMNAWAVE"
  echo "Схема: CDN -> российский relay -> один exit ИЛИ пул нескольких exit VPS. RU-трафик выходит DIRECT с relay, остальное через выбранный exit/EXIT_POOL."
  user_prepare "Нужен один relay в РФ и минимум одна другая подключённая нода как exit. Для пула можно выбрать сразу несколько exit-нод."
  user_prepare "CDN/origin должен смотреть на relay, не на exit. Базовый CDN сначала проверь отдельно."
  if ! rm_panel_detected; then die "Запусти --cascade на сервере центральной Remnawave-панели."; fi
  ok "Панель найдена: ${RM_API_BASE}. Версия: $(rm_panel_version || echo unknown)"
  if token=$(rm_get_token); then
    :
  else
    local _token_rc=$?
    [[ $_token_rc -eq 10 ]] && return 0
    warn "Для автоматического каскада нужен API token; без него изменения панели не выполняю."
    return 0
  fi
  nodes=$(rm_nodes_json "$token") || true
  count=$(jq 'length' <<<"$nodes")
  if (( count < 2 )); then
    warn "Для каскада нужны минимум две ноды, а API видит: $count."
    manual_do "Создай/подключи exit-ноду, затем снова запусти: $INSTALL_PATH --cascade"
    return 0
  fi

  local _cascade_selection_done=no
  while true; do
    echo
    ui_title "ВЫБОР RELAY"
    relay=$(rm_choose_node "$token") || return 0
    relay_uuid=$(jq -r '.uuid' <<<"$relay"); relay_name=$(jq -r '.name' <<<"$relay"); relay_ip=$(jq -r '.address' <<<"$relay")
    panel_public_ip=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
    if valid_ipv4 "$relay_ip"; then
      relay_addr_ip="$relay_ip"
    else
      relay_addr_ip=$(getent ahostsv4 "$relay_ip" 2>/dev/null | awk 'NR==1{print $1}' || true)
    fi
    relay_on_panel=no
    if local_remna_panel_present && [[ -n "$panel_public_ip" && "$relay_addr_ip" == "$panel_public_ip" ]]; then
      relay_on_panel=yes
      danger "Выбранный relay находится на ЭТОМ ЖЕ VPS, где работает Remnawave-панель."
      manual_do "Не запускай отдельный Caddy на :80/:443 — он конфликтует с nginx панели. Для origin используй отдельный server_name в существующем nginx -> 127.0.0.1:7443."
    fi

    while true; do
      echo
      ui_title "РЕЖИМ EXIT"
      echo "  1 — одна exit-нода"
      echo "  2 — несколько exit-нод (пул, балансировка соединений)"
      echo "  0 — назад к выбору relay"
      read -r -p "Выбор [1]: " exit_mode_choice; exit_mode_choice="${exit_mode_choice:-1}"
      case "$exit_mode_choice" in
        0) break ;;
        2)
          exit_mode=pool
          if ! exits=$(rm_choose_multiple_nodes "$token" "$relay_uuid"); then
            continue
          fi
          exit_count=$(jq 'length' <<<"$exits")
          if (( exit_count < 2 )); then
            warn "Для пула выбрана только одна exit-нода — переключаюсь в одиночный режим."
            exit_mode=single
          fi
          ;;
        1|"")
          exit_mode=single
          echo
          ui_title "ВЫБОР EXIT"
          if ! e=$(rm_choose_node "$token" "$relay_uuid"); then
            continue
          fi
          e_uuid=$(jq -r '.uuid' <<<"$e")
          exits=$(jq -nc --argjson e "$e" '[$e]')
          exit_count=1
          ;;
        *)
          warn "Выбери 1, 2 или 0."
          continue
          ;;
      esac

      strategy=roundRobin
      if [[ "$exit_mode" == pool ]]; then
        echo
        ui_title "СТРАТЕГИЯ EXIT-POOL"
        echo "  1 — roundRobin (по очереди; рекомендуется для первого теста)"
        echo "  2 — random (случайный exit для нового соединения)"
        echo "  0 — назад к выбору exit"
        echo "  leastPing/leastLoad здесь не включаю автоматически: для них нужен observatory."
        while true; do
          read -r -p "Выбор [1]: " strategy_choice; strategy_choice="${strategy_choice:-1}"
          case "$strategy_choice" in
            1|"") strategy=roundRobin; break ;;
            2) strategy=random; break ;;
            0) strategy=""; break ;;
            *) warn "Выбери 1, 2 или 0." ;;
          esac
        done
        [[ -z "$strategy" ]] && continue
      fi

      _cascade_selection_done=yes
      break
    done

    [[ "$_cascade_selection_done" == yes ]] && break
  done

  first_exit=$(jq -c '.[0]' <<<"$exits")
  first_exit_uuid=$(jq -r '.uuid' <<<"$first_exit")
  first_exit_ip=$(jq -r '.address' <<<"$first_exit")
  exit_keys=$(jq -r 'map(.uuid)|join(",")' <<<"$exits")

  method=$(rm_manager_choose_method) || return 0
  CASCADE_METHOD="$method"; CASCADE_RELAY_NODE_UUID="$relay_uuid"; CASCADE_RELAY_IP="$relay_ip"; CASCADE=yes
  CASCADE_EXIT_MODE="$exit_mode"; CASCADE_EXIT_NODE_UUID="$first_exit_uuid"; CASCADE_EXIT_NODE_UUIDS="$exit_keys"; CASCADE_EXIT_IP="$first_exit_ip"; CASCADE_EXIT_IPS=$(jq -r 'map(.address)|join(",")' <<<"$exits"); CASCADE_STRATEGY="$strategy"
  rm_manager_collect_domains "$method"
  if [[ "$relay_on_panel" == yes && "$method" == turboflare && -z "${ORIGIN_DOMAIN:-}" ]]; then
    danger "TurboFlare origin по голому IP:443 нельзя безопасно совместить с панелью на том же :443."
    manual_do "Для relay на сервере панели задай отдельный origin-домен либо используй отдельный RU relay VPS. Каскад API пока не меняю."
    return 0
  fi
  save_state

  echo
  ui_title "ПОДГОТОВКА К ПЕРЕКЛЮЧЕНИЮ"
  user_prepare "Relay: $relay_name ($relay_ip)"
  i=0
  while (( i < exit_count )); do
    e=$(jq -c ".[$i]" <<<"$exits")
    user_prepare "Exit #$((i+1)): $(jq -r '.name' <<<"$e") ($(jq -r '.address' <<<"$e"))"
    i=$((i+1))
  done
  [[ "$exit_mode" == pool ]] && user_prepare "EXIT_POOL: $exit_count нод, strategy=$strategy. Балансируются НОВЫЕ соединения; один TCP-поток не суммирует скорость нескольких VPS."
  manual_do "DNS/origin CDN должен в итоге указывать на RELAY $relay_ip. Пока не меняй, если текущий direct-метод нужен рабочим."
  manual_do "На relay CDN XHTTP-inbound будет слушать 127.0.0.1:7443. На каждой exit BRIDGE_IN будет слушать TCP 8888."
  if [[ "$relay_on_panel" == yes ]]; then
    manual_do "Relay совмещён с панелью: существующий nginx панели сохраняется; нужен отдельный origin-vhost/server_name, проксирующий CDN path на 127.0.0.1:7443."
  fi
  ask_yes_no _CASCADE_CONTINUE "Продолжить подготовку сущностей каскада в Remnawave API?" "yes"
  [[ "$_CASCADE_CONTINUE" == yes ]] || return 0

  if [[ "$exit_mode" == single ]]; then
    # Совместимость с v1.2.0: для одиночного каскада сохраняем прежний suffix/profile name.
    pool_suffix=$(printf '%s%s' "$relay_uuid" "$first_exit_uuid" | sha256sum | cut -c1-6)
  else
    pool_suffix=$(printf '%s|%s' "$relay_uuid" "$exit_keys" | sha256sum | cut -c1-6)
  fi
  relay_tag="psv1-${method}-cascade-${pool_suffix}"
  relay_profile_name="psv1-cascade-${method}-${pool_suffix}"; relay_profile_name="${relay_profile_name:0:30}"
  run_dir="$RM_MANAGER_DIR/cascade-${method}-${pool_suffix}"
  mkdir -p "$run_dir"; chmod 700 "$run_dir"
  printf '%s\n' "$relay" | jq . > "$run_dir/relay-node-before.json"
  printf '%s\n' "$exits" | jq . > "$run_dir/selected-exits.json"

  # 1) Подготовить BRIDGE_IN на каждой exit-ноде, ничего не удаляя из её активного профиля.
  i=0
  while (( i < exit_count )); do
    e=$(jq -c ".[$i]" <<<"$exits")
    e_uuid=$(jq -r '.uuid' <<<"$e"); e_name=$(jq -r '.name' <<<"$e"); e_ip=$(jq -r '.address' <<<"$e")
    e_suffix=$(printf '%s%s' "$relay_uuid" "$e_uuid" | sha256sum | cut -c1-6)
    bridge_tag="BRIDGE_IN-${e_suffix}"
    bridge_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16)
    exit_dir="$run_dir/exit-$((i+1))-${e_suffix}"
    mkdir -p "$exit_dir"; chmod 700 "$exit_dir"
    printf '%s\n' "$e" | jq . > "$exit_dir/node-before.json"

    exit_profile_uuid=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$e")
    bridge_inbound_uuid=""
    if [[ -z "$exit_profile_uuid" || "$exit_profile_uuid" == "00000000-0000-0000-0000-000000000000" ]]; then
      danger "Exit '$e_name' не имеет активного Config Profile. Создам отдельный bridge-only profile и назначу его."
      exit_profile_name="psv1-exit-bridge-${e_suffix}"
      if bridge_info=$(rm_api_create_bridge_only_profile "$token" "$e_uuid" "$bridge_tag" "$exit_profile_name"); then
        exit_profile_uuid=$(jq -r '.profileUuid' <<<"$bridge_info"); bridge_inbound_uuid=$(jq -r '.inboundUuid' <<<"$bridge_info")
        if rm_api_assign_node "$token" "$e_uuid" "$exit_profile_uuid" "$bridge_inbound_uuid"; then
          auto_done "Exit '$e_name': создан/назначен bridge-only profile, BRIDGE_IN активирован."
        else
          warn "Exit '$e_name': bridge profile создан, но нода не назначена автоматически."
        fi
      else
        warn "Exit '$e_name': не удалось создать bridge-only profile. Relay не переключаю."
        return 0
      fi
    else
      if bridge_info=$(rm_api_ensure_bridge_in_active_profile "$token" "$e" "$bridge_tag" "$exit_dir"); then
        exit_profile_uuid=$(jq -r '.profileUuid' <<<"$bridge_info"); bridge_inbound_uuid=$(jq -r '.inboundUuid' <<<"$bridge_info"); bridge_tag=$(jq -r '.tag' <<<"$bridge_info")
        if rm_api_add_active_inbound_preserve "$token" "$e" "$exit_profile_uuid" "$bridge_inbound_uuid"; then
          auto_done "Exit '$e_name': BRIDGE_IN ($bridge_tag :8888) добавлен в активный profile/Active Inbounds без удаления старых inbound'ов."
        else
          warn "Exit '$e_name': BRIDGE_IN создан, но Active Inbounds не обновлён автоматически."
        fi
      else
        warn "Exit '$e_name': не удалось безопасно добавить BRIDGE_IN. Останавливаюсь до переключения relay."
        return 0
      fi
    fi

    record=$(jq -nc --arg uuid "$e_uuid" --arg name "$e_name" --arg ip "$e_ip" --arg suffix "$e_suffix" --arg bt "$bridge_tag" --arg bi "$bridge_inbound_uuid" --arg bp "$exit_profile_uuid" --arg bu "$bridge_uuid" '{uuid:$uuid,name:$name,ip:$ip,suffix:$suffix,bridgeTag:$bt,bridgeInboundUuid:$bi,bridgeProfileUuid:$bp,bridgeUuid:$bu}')
    exit_records=$(jq -c --argjson a "$exit_records" --argjson r "$record" '$a + [$r]' <<< '{}')
    i=$((i+1))
  done

  # 2) Squad + отдельный bridge-user/UUID на каждый exit. На повторном запуске переиспользуется существующий пользователь.
  squad_uuid=""
  i=0
  while (( i < exit_count )); do
    bridge_inbound_uuid=$(jq -r ".[$i].bridgeInboundUuid" <<<"$exit_records")
    squad_uuid=$(rm_api_ensure_named_squad "$token" "PSV1-CASCADE" "$bridge_inbound_uuid" "" || true)
    [[ -n "$squad_uuid" ]] || { warn "Не удалось подготовить Internal Squad PSV1-CASCADE."; return 0; }
    i=$((i+1))
  done
  auto_done "Internal Squad PSV1-CASCADE содержит BRIDGE_IN всех выбранных exit."

  i=0
  while (( i < exit_count )); do
    e_suffix=$(jq -r ".[$i].suffix" <<<"$exit_records")
    bridge_uuid=$(jq -r ".[$i].bridgeUuid" <<<"$exit_records")
    user_name="bridge_${e_suffix}"
    if b=$(rm_api_ensure_bridge_user "$token" "$user_name" "$bridge_uuid" "$squad_uuid"); then
      bridge_uuid="$b"
      exit_records=$(jq -c --argjson i "$i" --arg b "$bridge_uuid" --arg u "$user_name" '.[$i].bridgeUuid=$b | .[$i].userName=$u' <<<"$exit_records")
      auto_done "Bridge user '$user_name' создан/найден для exit $(jq -r ".[$i].name" <<<"$exit_records")."
    else
      warn "Bridge user '$user_name' не настроен через API. Relay profile пока не создаю."
      return 0
    fi
    i=$((i+1))
  done
  printf '%s\n' "$exit_records" | jq . > "$run_dir/exit-pool.json"
  chmod 600 "$run_dir/exit-pool.json"
  CASCADE_BRIDGE_UUID=$(jq -r '.[0].bridgeUuid' <<<"$exit_records")

  # 3) Создать/обновить relay profile. Для >1 exit финальные правила используют balancerTag=EXIT_POOL.
  relay_config=$(rm_cascade_relay_config_json "$method" "$relay_tag" "$exit_records" "$strategy")
  printf '%s\n' "$relay_config" | jq . > "$run_dir/relay-profile.json"
  if relay_ids=$(rm_api_existing_profile "$token" "$relay_profile_name" 2>/dev/null); then
    relay_profile_uuid=$(jq -r '.profileUuid' <<<"$relay_ids"); relay_inbound_uuid=$(jq -r '.inboundUuid' <<<"$relay_ids")
    profile_doc=$(rm_api_profile_doc "$token" "$relay_profile_uuid" || true)
    existing_cfg=$(jq -c '.config // empty' <<<"$profile_doc" 2>/dev/null || true)
    if [[ -n "$existing_cfg" ]]; then
      desired_hash=$(printf '%s' "$relay_config" | jq -cS . | sha256sum | awk '{print $1}')
      current_hash=$(printf '%s' "$existing_cfg" | jq -cS . | sha256sum | awk '{print $1}')
      if [[ "$desired_hash" != "$current_hash" ]]; then
        danger "Существующий cascade profile отличается: изменился список exit, UUID или стратегия."
        ask_yes_no update_profile "Обновить ТОЛЬКО этот cascade profile, сохранив backup?" "no"
        if [[ "$update_profile" == yes ]]; then
          printf '%s\n' "$profile_doc" | jq . > "$run_dir/relay-profile-before-update.json"
          if rm_api_patch_profile_config "$token" "$relay_profile_uuid" "$relay_config"; then
            inbs=$(rm_api_profile_inbounds "$token" "$relay_profile_uuid")
            relay_inbound_uuid=$(jq -r --arg t "$relay_tag" '[.[]? | select(.tag==$t) | .uuid][0] // empty' <<<"$inbs")
            auto_done "Relay cascade profile обновлён."
          else
            warn "Relay profile не обновлён; assignment не меняю."; return 0
          fi
        else
          manual_do "Существующий cascade profile оставлен без изменений. Повтори --cascade и подтверди обновление, когда будешь готов."
          return 0
        fi
      fi
    fi
    auto_done "Relay cascade profile найден: $relay_profile_name"
  else
    if relay_ids=$(rm_api_create_profile "$token" "$relay_profile_name" "$relay_config"); then
      relay_profile_uuid=$(jq -r '.profileUuid' <<<"$relay_ids"); relay_inbound_uuid=$(jq -r '.inboundUuid' <<<"$relay_ids")
      auto_done "Relay cascade profile создан: $relay_profile_name"
    else
      warn "Не удалось создать relay cascade profile. Exit BRIDGE_IN оставлены, но трафик не переключался."; return 0
    fi
  fi

  # Добавить relay inbound в тот же Squad, сохранив все BRIDGE_IN.
  i=0
  while (( i < exit_count )); do
    bridge_inbound_uuid=$(jq -r ".[$i].bridgeInboundUuid" <<<"$exit_records")
    squad_uuid=$(rm_api_ensure_named_squad "$token" "PSV1-CASCADE" "$bridge_inbound_uuid" "$relay_inbound_uuid" || true)
    i=$((i+1))
  done
  [[ -n "$squad_uuid" ]] && auto_done "PSV1-CASCADE содержит relay inbound и все BRIDGE_IN." || warn "Cascade squad не удалось финализировать автоматически."

  relay_active=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$relay")
  if [[ -n "$relay_active" && "$relay_active" != "00000000-0000-0000-0000-000000000000" && "$relay_active" != "$relay_profile_uuid" ]]; then
    danger "Relay сейчас работает на другом profile UUID=$relay_active. Переключение изменит маршрутизацию этой ноды."
    manual_do "Backup текущего node JSON сохранён: $run_dir/relay-node-before.json"
    ask_yes_no RM_CASCADE_ASSIGN_RELAY "Назначить relay cascade profile '$relay_profile_name' сейчас?" "no"
  else
    RM_CASCADE_ASSIGN_RELAY=yes
  fi
  if [[ "$RM_CASCADE_ASSIGN_RELAY" == yes ]]; then
    if rm_api_assign_node "$token" "$relay_uuid" "$relay_profile_uuid" "$relay_inbound_uuid"; then
      auto_done "Relay: cascade profile назначен, XHTTP inbound :7443 активирован."
    else
      warn "Relay profile создан, но Node assignment не прошёл."
    fi
  else
    manual_do "Relay не переключён. После подготовки Caddy назначь profile '$relay_profile_name' и Active Inbound '$relay_tag'."
  fi

  if [[ -n "$CDN_DOMAIN" ]]; then
    extra=$(rm_method_host_extra_json "$method" "$(jq -c '.inbounds[0]' <<<"$relay_config")")
    host_uuid=$(rm_api_existing_host "$token" "$relay_profile_uuid" "$relay_inbound_uuid" "$CDN_DOMAIN" || true)
    if [[ -z "$host_uuid" ]]; then
      host_uuid=$(rm_api_create_host "$token" "$relay_profile_uuid" "$relay_inbound_uuid" "$method" "$CDN_DOMAIN" "PSV1 Cascade $(method_title "$method") - $relay_name" "$extra" || true)
    fi
    [[ -n "$host_uuid" ]] && auto_done "Cascade Host создан/найден: $CDN_DOMAIN -> relay inbound." || warn "Cascade Host не создан автоматически."
  fi

  if [[ "$relay_on_panel" == yes ]]; then
    relay_proxy_note="3. Relay находится на VPS панели: НЕ запускать Caddy на :80/:443. Сохрани nginx панели и добавь отдельный origin server_name -> 127.0.0.1:7443."
  else
    relay_proxy_note="3. По присланному мануалу отдельный relay использует Caddy, не nginx; точный Caddyfile установщик не выдумывает."
  fi
  cat > "$run_dir/RELAY-STEPS.txt" <<EOF
RELAY ($relay_name / $relay_ip)
1. CDN/origin должен смотреть на $relay_ip.
2. Remnawave relay inbound: 127.0.0.1:7443, tag=$relay_tag.
$relay_proxy_note
4. Node management port разрешай только от IP панели.
5. Режим exit: $exit_mode; strategy=$strategy; exits=$exit_count.
EOF

  : > "$run_dir/EXIT-STEPS.txt"
  : > "$run_dir/VERIFY.txt"
  i=0
  while (( i < exit_count )); do
    e_name=$(jq -r ".[$i].name" <<<"$exit_records")
    e_ip=$(jq -r ".[$i].ip" <<<"$exit_records")
    bridge_tag=$(jq -r ".[$i].bridgeTag" <<<"$exit_records")
    user_name=$(jq -r ".[$i].userName" <<<"$exit_records")
    cat >> "$run_dir/EXIT-STEPS.txt" <<EOF
EXIT #$((i+1)) ($e_name / $e_ip)
- BRIDGE_IN: TCP 8888, listen 0.0.0.0, tag=$bridge_tag.
- BRIDGE_IN должен быть в activeInbounds активного profile.
- Bridge user: $user_name; он и BRIDGE_IN должны быть в PSV1-CASCADE.
- Firewall/SG: разреши TCP 8888 от relay $relay_ip.
- Проверка на exit: ss -ltnp | grep 8888

EOF
    cat >> "$run_dir/VERIFY.txt" <<EOF
# Relay -> exit #$((i+1)) $e_name
nc -zv $e_ip 8888

EOF
    i=$((i+1))
  done
  cat >> "$run_dir/VERIFY.txt" <<EOF
# После CDN/origin переключения
curl -sk https://${CDN_DOMAIN:-CDN_DOMAIN}$(rm_method_meta "$method" path) -o /dev/null -w '%{http_code}\\n'
# ожидается 400 после рабочей цепочки

# Гео-проверка с клиента через VPN
# RU -> IP relay
# зарубежные -> один из выбранных exit; при roundRobin/random IP может меняться между НОВЫМИ соединениями.
EOF
  if [[ "$relay_on_panel" == yes ]]; then
    relay_proxy_note="1. Relay на VPS панели: НЕ запускать Caddy на :80/:443; добавить отдельный nginx origin server_name -> 127.0.0.1:7443, не меняя panel vhost/сертификат."
  else
    relay_proxy_note="1. Relay: настроить Caddy -> 127.0.0.1:7443 по path выбранного CDN."
  fi
  cat > "$run_dir/MANUAL-ACTIONS.txt" <<EOF
[ВРУЧНУЮ] Перед финальным переключением
$relay_proxy_note
2. На КАЖДОЙ exit: TCP 8888 доступен с relay и BRIDGE_IN слушает.
3. DNS/CDN provider: origin должен указывать на RELAY $relay_ip, не на exit.
4. Users: обычные пользователи, которым нужен cascade Host, должны иметь доступ к Internal Squad с relay inbound.
5. Для пула: strategy=$strategy. Это балансировка соединений, а не суммирование пропускной способности одного потока.
EOF
  chmod 600 "$run_dir"/*.txt "$run_dir"/*.json "$run_dir"/exit-*/*.json 2>/dev/null || true
  CASCADE_STATUS=prepared; save_state

  echo
  ui_title "КАСКАД — ИТОГ"
  auto_done "Relay cascade profile: $relay_profile_name"
  if [[ "$exit_mode" == pool ]]; then
    auto_done "EXIT_POOL: $exit_count exit-нод, strategy=$strategy, balancerTag=EXIT_POOL."
  else
    auto_done "Одиночный exit: $(jq -r '.[0].name' <<<"$exit_records") ($(jq -r '.[0].ip' <<<"$exit_records"))."
  fi
  auto_done "На каждой exit подготовлен BRIDGE_IN :8888 и отдельный bridge-user."
  [[ -n "$squad_uuid" ]] && auto_done "Internal Squad: PSV1-CASCADE"
  [[ -n "$host_uuid" ]] && auto_done "Cascade Host: $CDN_DOMAIN"
  manual_do "Provider-side origin/DNS и reverse proxy relay требуют отдельного действия (отдельный relay: Caddy; relay на VPS панели: существующий nginx)."
  manual_do "Инструкция relay: $run_dir/RELAY-STEPS.txt"
  manual_do "Все exit:        $run_dir/EXIT-STEPS.txt"
  check_do "Проверки:       $run_dir/VERIFY.txt"
  echo
  echo "Повторно открыть мастер каскада: $INSTALL_PATH --cascade"
}

run_3xui_cascade_manager(){
  local exit_ip bridge_uuid out="$OUT_DIR/3xui-cascade"
  mkdir -p "$out"; chmod 700 "$out"
  ui_title "КАСКАД 3x-ui"
  user_prepare "В этом проекте каскад 3x-ui поддерживается только для VK/Yandex/TurboFlare."
  read -r -p "IPv4 заграничного exit-сервера: " exit_ip
  valid_ipv4 "$exit_ip" || die "Нужен IPv4 exit-сервера."
  bridge_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16)
  cat > "$out/NEXT-STEPS.txt" <<EOF
3x-ui CASCADE
1. На exit: VLESS TCP inbound :8888, security=none, UUID=$bridge_uuid.
2. На relay в xrayTemplateConfig добавить outbound CASCADE-REALITY -> $exit_ip:8888 с этим UUID.
3. Финальное routing-правило должно быть catch-all по network \"tcp,udp\", НЕ inboundTag.
4. RU-direct и блокировки должны стоять ВЫШЕ catch-all.
5. xrayTemplateConfig в SQLite менять через DELETE + INSERT; затем systemctl restart x-ui.
6. Проверить: nc -zv $exit_ip 8888; затем гео — RU через relay, зарубежные через exit.
EOF
  chmod 600 "$out/NEXT-STEPS.txt"
  warn "Автоматическая правка xrayTemplateConfig 3x-ui пока не включена: это отдельный рискованный DB-шаг. Готов точный чек-лист: $out/NEXT-STEPS.txt"
}

run_cascade_manager(){
  load_state || true
  if rm_panel_detected >/dev/null 2>&1; then
    run_remna_cascade_manager
  elif [[ "${PANEL_KIND:-}" == 3xui ]] || command -v x-ui >/dev/null 2>&1 || [[ -d /etc/x-ui ]]; then
    run_3xui_cascade_manager
  else
    die "Не вижу локальную центральную Remnawave или 3x-ui. Для Remnawave запускай --cascade на сервере панели."
  fi
}


run_remna_panel_manager(){
  local token="" token_mode=api nodes node node_uuid node_name node_ip connected method safe suffix tag inbound config extra profile_name ids profile_uuid inbound_uuid active_profile assign_ok=no host_uuid="" squad_ok=no run_dir summary technew=""
  echo
  echo "=== Remnawave: добавить CDN-метод в существующую панель ==="
  echo "Этот режим НЕ переустанавливает панель и НЕ удаляет существующие профили/хосты."
  command -v jq >/dev/null 2>&1 || { apt-get update && apt-get install -y jq; }

  if rm_panel_detected; then
    ok "Панель найдена. API: ${RM_API_BASE}. Версия образа: $(rm_panel_version || echo unknown)"
  else
    warn "Remnawave установлена/была установлена, но API автоматически не найден."
    echo "Это больше НЕ останавливает мастер: можно указать URL панели или получить готовую ручную инструкцию."
    local entered_url=""
    read -r -p "URL панели (пример https://panel.example.com; Enter = ручной режим): " entered_url
    if [[ -n "$entered_url" ]] && rm_try_api_base "$entered_url"; then
      ok "API панели найден по адресу ${RM_API_BASE}."
    else
      token_mode=manual
      token=""
    fi
  fi

  if [[ "$token_mode" == api ]]; then
    # Keep non-zero returns inside an `if`: this suppresses the global ERR trap
    # and lets the wizard offer a retry instead of aborting with code 2.
    if token=$(rm_get_token); then
      :
    else
      rc=$?
      if [[ $rc -eq 10 ]]; then
        return 0
      elif [[ $rc -eq 4 ]]; then
        warn "Похоже, был вставлен UUID токена. Запусти менеджер ещё раз и выбери логин/пароль либо вставь настоящий API token."
        token_mode=manual; token=""
      elif [[ $rc -eq 2 ]]; then
        token_mode=manual; token=""
      else
        warn "API-вход не получился; продолжу в ручном режиме."
        token_mode=manual; token=""
      fi
    fi
  fi

  if [[ "$token_mode" == api ]]; then
    if node=$(rm_choose_node "$token"); then rc=0; else rc=$?; fi
    if [[ $rc -eq 2 || $rc -eq 3 ]]; then
      echo
      if [[ $rc -eq 3 ]]; then
        warn "Текущий токен принят панелью, но GET /api/nodes не вернул пригодного JSON-ответа."
      else
        warn "GET /api/nodes вернул JSON, но список нод через этот способ авторизации пуст/не распознан."
      fi
      [[ -s "$RM_MANAGER_DIR/last-nodes-http.txt" ]] && { echo "Диагностика API:"; cat "$RM_MANAGER_DIR/last-nodes-http.txt"; }
      echo "В веб-панели нода может при этом быть видна. Вторую ноду создавать НЕ нужно."
      echo
      echo "Попробовать получить список нод через обычный admin JWT (логин/пароль панели)?"
      echo "  1 — да, войти администратором и продолжить автоматически"
      echo "  2 — перейти в ручной режим с готовыми JSON"
      echo "  0 — назад"
      read -r -p "Выбор [1]: " retry_choice; retry_choice="${retry_choice:-1}"
      case "$retry_choice" in
        1)
          if token=$(rm_admin_jwt_prompt); then
            if node=$(rm_choose_node "$token"); then rc=0; else rc=$?; fi
            if [[ $rc -ne 0 ]]; then
              warn "Даже admin JWT не дал список нод. Ничего в панели не изменяю."
              [[ -s "$RM_MANAGER_DIR/last-nodes-http.txt" ]] && cat "$RM_MANAGER_DIR/last-nodes-http.txt"
              token_mode=manual
            fi
          else
            token_mode=manual
          fi
          ;;
        2) token_mode=manual ;;
        0) return 0 ;;
        *) token_mode=manual ;;
      esac
      if [[ "$token_mode" == manual ]]; then
        echo
        warn "Перехожу в ручной режим: подготовлю точные profile/host/xhttpExtraParams и инструкции, существующее не меняю."
        read -r -p "Имя ноды в панели: " node_name
        read -r -p "Публичный IPv4 европейской ноды: " node_ip
        valid_ipv4 "$node_ip" || die "Нужен IPv4 ноды."
        node_uuid="manual"
      fi
    elif [[ $rc -eq 1 ]]; then
      return 0
    elif [[ $rc -ne 0 ]]; then
      die "Не удалось выбрать ноду."
    fi
    if [[ "$token_mode" == api ]]; then
      node_uuid=$(jq -r '.uuid' <<<"$node"); node_name=$(jq -r '.name // .uuid' <<<"$node"); node_ip=$(jq -r '.address // empty' <<<"$node")
      connected=$(jq -r '.isConnected // .is_connected // false' <<<"$node")
      [[ "$connected" == true ]] || warn "Нода сейчас не отмечена Connected. Настройку создать можно, но тест 400 появится только после подключения ноды."
    fi
  else
    echo
    warn "Ручной режим: API панель не изменяет. Я подготовлю готовые JSON/параметры."
    read -r -p "Имя ноды в панели: " node_name
    read -r -p "Публичный IPv4 европейской ноды: " node_ip
    valid_ipv4 "$node_ip" || die "Нужен IPv4 ноды."
    node_uuid="manual"
  fi

  method=$(rm_manager_choose_method) || exit 0
  rm_manager_collect_domains "$method"
  ask_yes_no USE_CLOUDFLARE "Использовать Cloudflare для DNS-записей там, где это применимо?" "${USE_CLOUDFLARE:-yes}"
  save_state
  show_provider_preflight "$method" "$node_ip"
  ask_yes_no RM_CONTINUE_AFTER_PREP "Продолжить автоматическую настройку Remnawave?" "yes"
  [[ "$RM_CONTINUE_AFTER_PREP" == yes ]] || { manual_do "Остановлено до изменений панели. Подготовь CDN/DNS и запусти --manage-remna снова."; return 0; }
  safe=$(tr '[:upper:]' '[:lower:]' <<<"$node_name" | tr -cd 'a-z0-9_-'); [[ -n "$safe" ]] || safe="node"
  suffix=$(printf '%s' "$node_uuid" | sha256sum | cut -c1-6)
  tag="psv1-${method}-${suffix}"
  # Remnawave API limits Config Profile names to 30 characters.
  # Build a readable but always-valid name instead of letting POST /api/config-profiles fail.
  profile_prefix="psv1-${method}-"
  max_safe=$((30 - ${#profile_prefix} - 1 - ${#suffix}))
  (( max_safe < 1 )) && max_safe=1
  safe="${safe:0:max_safe}"
  profile_name="${profile_prefix}${safe}-${suffix}"
  inbound=$(rm_method_inbound_json "$method" "$tag")
  config=$(rm_profile_config_json "$inbound" "$method")
  extra=$(rm_method_host_extra_json "$method" "$inbound")
  run_dir="$RM_MANAGER_DIR/${profile_name}"
  mkdir -p "$run_dir"; chmod 700 "$run_dir"
  printf '%s\n' "$config" | jq . > "$run_dir/profile.json"
  printf '%s\n' "$extra" | jq . > "$run_dir/xhttpExtraParams.json"
  cat > "$run_dir/host.txt" <<EOF
Address: ${CDN_DOMAIN:-<введи технический CDN-домен после активации ресурса>}
SNI/Host: ${CDN_DOMAIN:-<тот же домен>}
Port: 443
Path: $(rm_method_meta "$method" path)
ALPN: $(rm_method_meta "$method" alpn)
Fingerprint: $(rm_method_meta "$method" fp)
Security: TLS
Inbound tag: $tag
EOF
  rm_manager_provider_steps "$method" "$node_ip" "$run_dir/provider-steps.txt"

  cat > "$run_dir/NEXT-STEPS.txt" <<EOF
ПАНЕЛЬ REMNAWAVE — обязательная цепочка для $(method_title "$method")
================================================================
1. Config Profiles → Create profile
   Имя: $profile_name
   Вставить содержимое: $run_dir/profile.json
   Внутри уже зашит Xray inbound '$tag' с нужным XHTTP preset.

2. Nodes → '$node_name' → Change Profile
   Выбрать: $profile_name
   В Active inbounds ОБЯЗАТЕЛЬНО включить '$tag'.
   Без этой галочки Xray на ноде не поднимет CDN-порт.

3. Internal Squads
   Открыть Default-Squad или создать отдельный squad и добавить inbound '$tag'.

4. Users
   Для каждого пользователя, которому нужен этот CDN: Active internal squads → отметить squad из шага 3.
   Иначе подписка может вернуть No hosts found.

5. Hosts → Create host
   Все значения взять из: $run_dir/host.txt
   xhttpExtraParams вставить БЕЗ ИЗМЕНЕНИЙ из: $run_dir/xhttpExtraParams.json

6. Подписка → Xray JSON
   Скрипт после создания Host предложит создать отдельный XRAY_JSON шаблон для этого метода.
   В шаблон добавляется remnawave.addVirtualHostAsOutbound=true, затем шаблон назначается созданному Host.
   Новый шаблон поднимается вверх списка, а Default уходит вниз.
   Удаление Default возможно только отдельным подтверждением и по умолчанию ВЫКЛ.

7. External Squads
   Скрипт предложит отдельный External Squad и привяжет к нему этот Xray JSON шаблон.
   Пользователей массово туда НЕ переносит без отдельного подтверждения.

8. CDN-провайдер
   Выполнить: $run_dir/provider-steps.txt

Проверка цепочки после активации:
  профиль содержит inbound → профиль назначен ноде → inbound Active → inbound в Internal Squad → пользователь в этом Squad → Host привязан к inbound.
Ничего существующего удалять не нужно.
EOF

  if [[ "$token_mode" == manual ]]; then
    ok "Готов комплект ручной настройки: $run_dir"
    cat "$run_dir/NEXT-STEPS.txt"
    return 0
  fi

  # Reuse the profile created by a previous run, otherwise create a new one.
  if ids=$(rm_api_existing_profile "$token" "$profile_name" 2>/dev/null); then
    profile_uuid=$(jq -r '.profileUuid' <<<"$ids"); inbound_uuid=$(jq -r '.inboundUuid' <<<"$ids")
    ok "Профиль $profile_name уже существует — использую его, не перезаписываю."
  else
    if ids=$(rm_api_create_profile "$token" "$profile_name" "$config"); then
      profile_uuid=$(jq -r '.profileUuid' <<<"$ids"); inbound_uuid=$(jq -r '.inboundUuid' <<<"$ids")
      ok "Создан новый Config Profile: $profile_name"
    else
      warn "API не создал профиль. Ничего существующего не изменено."
      [[ -s "$RM_MANAGER_DIR/last-api-error-create-profile-http.txt" ]] && { echo "Диагностика создания профиля:"; cat "$RM_MANAGER_DIR/last-api-error-create-profile-http.txt"; }
      if [[ -s "$RM_MANAGER_DIR/last-api-error-create-profile.json" ]]; then
        echo "Ответ API:"
        jq . "$RM_MANAGER_DIR/last-api-error-create-profile.json" 2>/dev/null || cat "$RM_MANAGER_DIR/last-api-error-create-profile.json"
      fi
      echo "Полная пошаговая инструкция: $run_dir/NEXT-STEPS.txt"
      cat "$run_dir/NEXT-STEPS.txt"
      return 0
    fi
  fi

  active_profile=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$node")
  if [[ -n "$active_profile" && "$active_profile" != "$profile_uuid" ]]; then
    warn "У выбранной ноды уже есть другой активный профиль ($active_profile)."
    warn "Чтобы не выключить действующий метод на ЭТОЙ же ноде, автоматическую замену не делаю без подтверждения."
    ask_yes_no RM_REPLACE_PROFILE "Заменить профиль именно у этой ноды на $profile_name?" "no"
  else RM_REPLACE_PROFILE=yes; fi
  if [[ "$RM_REPLACE_PROFILE" == yes ]]; then
    if rm_api_assign_node "$token" "$node_uuid" "$profile_uuid" "$inbound_uuid"; then
      assign_ok=yes; ok "Профиль назначен ноде; inbound активирован."
    else
      warn "Автопривязка ноды через API не прошла. Профиль создан, но ноду не трогал дальше."
      warn "В панели: Nodes → $node_name → Change Profile → $profile_name → включить inbound $tag."
    fi
  else
    warn "Профиль ноды не менялся. Назначь $profile_name вручную, когда будешь готов."
  fi

  if rm_api_add_to_squad "$token" "$inbound_uuid"; then squad_ok=yes; ok "Inbound добавлен в выбранный Internal Squad без удаления старых inbound'ов."; else warn "Squad автоматически не изменён. Добавь inbound '$tag' в нужный Internal Squad вручную."; fi

  if [[ -z "$CDN_DOMAIN" && ( "$method" == selectel || "$method" == beeline ) ]]; then
    echo
    ui_title "НУЖЕН ТЕХНИЧЕСКИЙ ДОМЕН CDN"
    manual_do "Сейчас создай/активируй ресурс у провайдера по инструкции выше и скопируй выданный технический домен."
    if [[ "$method" == selectel ]]; then
      manual_do "Ожидается домен вида xxxx.selcdn.net."
    else
      manual_do "Ожидается домен вида xxx.a.trbcdn.net."
    fi
    read -r -p "Технический CDN-домен (Enter = оставить Host на потом): " technew
    if [[ -n "$technew" ]]; then
      technew="${technew,,}"
      if valid_domain "$technew"; then CDN_DOMAIN="$technew"; save_state; else warn "Некорректный домен — Host пока не создаю."; fi
    fi
  fi

  if [[ -n "$CDN_DOMAIN" ]]; then
    host_uuid=$(rm_api_existing_host "$token" "$profile_uuid" "$inbound_uuid" "$CDN_DOMAIN" || true)
    if [[ -n "$host_uuid" ]]; then
      ok "Host для $CDN_DOMAIN уже существует — дубликат не создаю."
    elif host_uuid=$(rm_api_create_host "$token" "$profile_uuid" "$inbound_uuid" "$method" "$CDN_DOMAIN" "PSV1 $(method_title "$method") - $node_name" "$extra"); then
      ok "Host создан в панели: $CDN_DOMAIN"
    else
      warn "Host через API не создался. Профиль/нода не удалены; создай Host по файлам $run_dir/host.txt и xhttpExtraParams.json."
    fi
  else
    warn "Технический CDN-домен ещё неизвестен — Host пока не создаю. После выдачи домена снова запусти менеджер; существующий профиль будет использован повторно."
  fi

  if [[ -n "${host_uuid:-}" ]]; then
    rm_manage_xray_subscription_layer "$token" "$method" "$node_name" "$run_dir" "$host_uuid"
  else
    warn "Xray JSON/External Squad отложены до создания Host."
  fi

  summary="$run_dir/result.txt"
  cat > "$summary" <<EOF
Remnawave panel manager $INSTALLER_VERSION
Node: $node_name ($node_ip) UUID=$node_uuid
Method: $(method_title "$method")
Profile: $profile_name UUID=$profile_uuid
Inbound tag/UUID: $tag / $inbound_uuid
Node assigned automatically: $assign_ok
Squad updated automatically: $squad_ok
Host UUID: ${host_uuid:-not-created-yet}
CDN domain: ${CDN_DOMAIN:-not-known-yet}
Xray JSON template: ${RM_XRAY_TEMPLATE_UUID:-not-created-or-skipped}
Host Xray template bound: ${RM_HOST_XRAY_TEMPLATE_OK:-no}
External Squad: ${RM_EXTERNAL_SQUAD_UUID:-not-created-or-skipped}
Provider instructions: $run_dir/provider-steps.txt
EOF
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$node_uuid" "$method" "$profile_uuid" "$inbound_uuid" "${host_uuid:-}" >> "$RM_MANAGER_DIR/registry.tsv"
  chmod 600 "$run_dir"/* "$RM_MANAGER_DIR/registry.tsv" 2>/dev/null || true
  echo
  ui_title "ИТОГ — ЧТО СДЕЛАНО АВТОМАТИЧЕСКИ"
  auto_done "Node: $node_name ($node_ip)"
  auto_done "Config Profile: $profile_name"
  [[ "$assign_ok" == yes ]] && auto_done "Profile назначен ноде; inbound '$tag' активирован." || manual_do "Назначь Profile/inbound ноде вручную."
  [[ "$squad_ok" == yes ]] && auto_done "Inbound добавлен в Internal Squad." || manual_do "Добавь inbound '$tag' в Internal Squad."
  [[ -n "${host_uuid:-}" ]] && auto_done "Host: ${CDN_DOMAIN} (UUID ${host_uuid})" || manual_do "Host ещё не создан."
  [[ "${RM_XRAY_TEMPLATE_OK:-no}" == yes ]] && auto_done "Отдельный Xray JSON шаблон: PSV1 $(method_title "$method")."
  [[ "${RM_HOST_XRAY_TEMPLATE_OK:-no}" == yes ]] && auto_done "Xray JSON шаблон назначен созданному Host."
  [[ "${RM_DEFAULT_MOVED:-no}" == yes ]] && auto_done "Default Xray JSON перемещён вниз списка."
  [[ "${RM_EXTERNAL_SQUAD_OK:-no}" == yes ]] && auto_done "External Squad создан и связан с Xray JSON шаблоном."
  [[ "${RM_DEFAULT_DELETED:-no}" == yes ]] && auto_done "Default Xray JSON удалён по твоему подтверждению."

  ui_title "ЧТО НУЖНО ПРОВЕРИТЬ/ДОДЕЛАТЬ"
  manual_do "Users: нужный пользователь должен состоять в Internal Squad, где активирован '$tag'."
  if [[ -n "${host_uuid:-}" && "${RM_XRAY_TEMPLATE_OK:-no}" != yes ]]; then
    manual_do "Подписка -> Xray JSON: создай XRAY_JSON шаблон 'PSV1 $(method_title "$method")' и вставь $run_dir/xray-subscription-template.json."
  elif [[ "${RM_XRAY_TEMPLATE_OK:-no}" == yes && "${RM_HOST_XRAY_TEMPLATE_OK:-no}" != yes ]]; then
    manual_do "Hosts -> ${CDN_DOMAIN} -> Xray JSON Template: выбери 'PSV1 $(method_title "$method")' и сохрани."
  fi
  if [[ "${RM_XRAY_TEMPLATE_OK:-no}" == yes && "${RM_EXTERNAL_SQUAD_OK:-no}" != yes ]]; then
    manual_do "External Squads: создай 'PSV1 $(method_title "$method")' и назначь ему Xray JSON шаблон 'PSV1 $(method_title "$method")'."
  fi
  if [[ "${RM_EXTERNAL_SQUAD_OK:-no}" == yes && "${RM_EXTERNAL_USERS_ALL:-no}" != yes ]]; then
    manual_do "Users: для отдельного Xray JSON выбери External Squad 'PSV1 $(method_title "$method")' у нужных пользователей."
  fi
  [[ "${RM_XRAY_TEMPLATE_OK:-no}" == yes && "${RM_DEFAULT_MOVED:-no}" != yes ]] && manual_do "Подписка -> Xray JSON: перетащи 'PSV1 $(method_title "$method")' выше Default."
  manual_do "Полный чек-лист сохранён: $run_dir/NEXT-STEPS.txt"

  {
    echo "РУЧНЫЕ ДЕЙСТВИЯ ПОСЛЕ АВТОМАТИКИ"
    echo "================================"
    echo "1. Users: пользователь должен состоять в Internal Squad с inbound '$tag'."
    stepn=2
    if [[ "${RM_XRAY_TEMPLATE_OK:-no}" == yes && "${RM_HOST_XRAY_TEMPLATE_OK:-no}" != yes ]]; then
      echo "${stepn}. Hosts -> ${CDN_DOMAIN} -> Xray JSON Template: выбери 'PSV1 $(method_title "$method")'."; stepn=$((stepn+1))
    fi
    if [[ "${RM_EXTERNAL_SQUAD_OK:-no}" == yes && "${RM_EXTERNAL_USERS_ALL:-no}" != yes ]]; then
      echo "${stepn}. Users: назначь нужным пользователям External Squad 'PSV1 $(method_title "$method")'."; stepn=$((stepn+1))
    elif [[ "${RM_XRAY_TEMPLATE_OK:-no}" == yes && "${RM_EXTERNAL_SQUAD_OK:-no}" != yes ]]; then
      echo "${stepn}. External Squads: создай отдельный squad и выбери в нём шаблон 'PSV1 $(method_title "$method")'."; stepn=$((stepn+1))
    fi
    echo "${stepn}. Выполни provider-side пункты из: $run_dir/provider-steps.txt"; stepn=$((stepn+1))
    echo "${stepn}. Проверь origin/CDN URL: ожидаемый HTTP-код XHTTP без клиента — 400."
  } > "$run_dir/MANUAL-ACTIONS.txt"
  chmod 600 "$run_dir/MANUAL-ACTIONS.txt" 2>/dev/null || true

  print_manual_file_colored "$run_dir/provider-steps.txt"
  echo
  check_do "После provider-side настройки проверь origin и CDN path; нормальный ответ XHTTP без клиента — HTTP 400."
  manual_do "Короткая итоговая инструкция сохранена: $run_dir/MANUAL-ACTIONS.txt"
}

show_config(){
  echo
  echo "================ Сохранённая конфигурация ================"
  echo "Панель          : $PANEL_KIND"
  [[ "$PANEL_KIND" == remna ]] && echo "Роль Remnawave  : ${REMNA_ROLE:-} / версия ${REMNA_VERSION:-}"
  [[ "$PANEL_KIND" == remna && ( "${REMNA_ROLE:-}" == node || "${REMNA_ROLE:-}" == both ) ]] && echo "Node Port       : ${REMNA_NODE_PORT:-не задан}"
  [[ "$PANEL_KIND" == 3xui ]] && echo "Версия 3x-ui    : ${XUI_VERSION:-}"
  echo "Метод           : $(method_title "${METHOD:-none}")"
  if [[ "${METHOD:-none}" != none ]]; then
    echo "CDN-домен       : ${CDN_DOMAIN:-будет введён позже}"
    echo "Origin-домен    : ${ORIGIN_DOMAIN:-не используется / IP}"
  fi
  echo "Домен панели    : ${PANEL_DOMAIN:-нет}"
  [[ "${METHOD:-none}" != none ]] && echo "Cloudflare DNS  : ${USE_CLOUDFLARE:-yes}"
  echo "Каскад          : ${CASCADE:-no}"
  if [[ "${CASCADE:-no}" == yes && -n "${CASCADE_EXIT_MODE:-}" ]]; then
    echo "Cascade exits   : ${CASCADE_EXIT_MODE} / ${CASCADE_EXIT_IPS:-${CASCADE_EXIT_IP:-}} / strategy=${CASCADE_STRATEGY:-roundRobin}"
  fi
  echo "Firewall / BBR  : ${ENABLE_UFW:-yes} / ${ENABLE_BBR:-yes}"
  echo "==========================================================="
}

choose_panel(){
  if [[ "$PRESET" == 3xui:* ]]; then PANEL_KIND=3xui; return 0; fi
  if [[ "$PRESET" == remna:* ]]; then PANEL_KIND=remna; return 0; fi
  echo
  echo "Выбери панель:"
  echo "  1 — Remnawave (все 6 методов; лучше для панели + множества нод)"
  echo "  2 — 3x-ui (только VK / Yandex / TurboFlare; совместимый режим v3.3.1)"
  echo "  0 — выйти"
  while true; do
    read -r -p "Выбор [1]: " a; a="${a:-1}"
    case "$a" in 1) PANEL_KIND=remna; return 0 ;; 2) PANEL_KIND=3xui; return 0 ;; 0) return 1 ;; esac
  done
}
choose_remna_role(){
  if [[ "${REMNA_EXISTING_PANEL_SIDE_BY_SIDE:-no}" == yes && "$PRESET" == "remna:none" ]]; then
    REMNA_ROLE=node
    return 0
  fi
  if local_remna_panel_present; then
    echo
    danger "На этом VPS уже обнаружена существующая Remnawave-панель. Переустановка панели заблокирована."
    echo "Что сделать с существующей Remnawave?"
    echo "  1 — добавить/настроить CDN-метод для существующей ноды"
    echo "  2 — добавить remnanode на ЭТОТ VPS БЕЗ CDN (relay/exit каскада)"
    echo "  3 — проверить существующую панель"
    echo "  0 — назад"
    while true; do
      read -r -p "Выбор [2]: " a; a="${a:-2}"
      case "$a" in
        1) exec "$0" --manage-remna ;;
        2) REMNA_ROLE=node; METHOD=none; PRESET="remna:none"; REMNA_EXISTING_PANEL_SIDE_BY_SIDE=yes; return 0 ;;
        3) exec "$0" --check-remna ;;
        0) return 1 ;;
        *) warn "Выбери 1, 2, 3 или 0." ;;
      esac
    done
  fi
  echo
  echo "Что сделать с Remnawave?"
  echo "  1 — установить новую центральную панель"
  echo "  2 — панель УЖЕ установлена: добавить/настроить CDN-метод для ноды"
  echo "  3 — установить только ноду на этом VPS"
  echo "  4 — установить панель + ноду на одном VPS"
  echo "  5 — проверить существующую панель"
  echo "  0 — назад"
  while true; do
    read -r -p "Выбор [2]: " a; a="${a:-2}"
    case "$a" in
      1) REMNA_ROLE=panel; return 0 ;;
      2) exec "$0" --manage-remna ;;
      3) REMNA_ROLE=node; return 0 ;;
      4) REMNA_ROLE=both; return 0 ;;
      5) exec "$0" --check-remna ;;
      0) return 1 ;;
    esac
  done
}
choose_remna_version(){
  echo
  echo "Версия Remnawave:"
  echo "  1 — $REMNA_MANUAL_VERSION (по присланным мануалам, рекомендуется для первого теста)"
  echo "  2 — $REMNA_NEWER_VERSION (новее; конфиги методов ещё надо перепроверить на практике)"
  echo "  0 — назад"
  while true; do
    read -r -p "Выбор [1]: " rv; rv="${rv:-1}"
    case "$rv" in
      1) REMNA_VERSION="$REMNA_MANUAL_VERSION"; return 0 ;;
      2) REMNA_VERSION="$REMNA_NEWER_VERSION"; return 0 ;;
      0) return 1 ;;
    esac
  done
}
choose_method(){
  if [[ -n "$PRESET" ]]; then
    METHOD="${PRESET#*:}"
    return 0
  fi
  echo
  if [[ "$PANEL_KIND" == 3xui ]]; then
    echo "Метод CDN (для 3x-ui доступны только проверенные в файлах):"
    echo "  1 — VK Cloud"
    echo "  2 — Yandex Cloud"
    echo "  3 — TurboFlare"
    echo "  0 — назад"
    while true; do
      read -r -p "Выбор [3]: " a; a="${a:-3}"
      case "$a" in 1) METHOD=vk; return 0 ;; 2) METHOD=yandex; return 0 ;; 3) METHOD=turboflare; return 0 ;; 0) return 1 ;; esac
    done
  else
    echo "Метод / назначение ноды:"
    echo "  1 — VK Cloud"
    echo "  2 — Yandex Cloud"
    echo "  3 — Beeline / CDNvideo"
    echo "  4 — Timeweb"
    echo "  5 — Selectel"
    echo "  6 — TurboFlare"
    if [[ "${REMNA_ROLE:-}" == node || "${REMNA_ROLE:-}" == both ]]; then
      echo "  7 — БЕЗ CDN — только нода для каскада (relay/exit)"
    fi
    echo "  0 — назад"
    local default_method=6
    if [[ "${REMNA_ROLE:-}" == node ]] && local_remna_panel_present; then
      default_method=7
      user_prepare "На этом VPS уже обнаружена Remnawave-панель: безопасный выбор по умолчанию — служебная нода БЕЗ CDN."
    fi
    while true; do
      read -r -p "Выбор [$default_method]: " a; a="${a:-$default_method}"
      case "$a" in
        1) METHOD=vk; return 0 ;;
        2) METHOD=yandex; return 0 ;;
        3) METHOD=beeline; return 0 ;;
        4) METHOD=timeweb; return 0 ;;
        5) METHOD=selectel; return 0 ;;
        6) METHOD=turboflare; return 0 ;;
        7) if [[ "${REMNA_ROLE:-}" == node || "${REMNA_ROLE:-}" == both ]]; then METHOD=none; return 0; fi ;;
        0) return 1 ;;
      esac
    done
  fi
}


collect_config(){
  echo
  echo "=== CDN/XHTTP Universal Installer $INSTALLER_VERSION ==="
  echo "Примеры доменов вымышленные; реальные домены в код не зашиваются."
  local _stage=panel
  while true; do
    case "$_stage" in
      panel)
        choose_panel || exit 0
        if [[ "$PANEL_KIND" == remna ]]; then _stage=remna_role; else _stage=xui_method; fi
        ;;
      remna_role)
        if choose_remna_role; then _stage=remna_version; else _stage=panel; fi
        ;;
      remna_version)
        if choose_remna_version; then
          XUI_VERSION=""
          if [[ "$REMNA_ROLE" == both ]]; then
            echo "Для panel+node выбери Node Port сейчас, а в окне создания ноды укажи ТО ЖЕ значение."
            ask_port REMNA_NODE_PORT "Node Port" "${REMNA_NODE_PORT:-2222}"
          fi
          if [[ "$REMNA_ROLE" == panel ]]; then METHOD=none; _stage=done; else _stage=remna_method; fi
        else
          _stage=remna_role
        fi
        ;;
      remna_method)
        if choose_method; then _stage=done; else _stage=remna_version; fi
        ;;
      xui_method)
        REMNA_ROLE=""; REMNA_VERSION=""
        XUI_VERSION="$XUI_COMPAT_VERSION"
        echo
        warn "3x-ui фиксируется на $XUI_VERSION: в этих мануалах ссылка строится через legacy External Proxy."
        warn "Новые версии 3x-ui используют другой механизм Hosts; их не включаю автоматически до отдельной проверки."
        ask_yes_no UPGRADE_XUI_XRAY "После установки заменить bundled Xray на $XRAY_MANUAL_VERSION? (мануалы рекомендуют; для уже рабочего TurboFlare 26.6.1 менять не обязательно)" "no"
        if choose_method; then _stage=done; else _stage=panel; fi
        ;;
      done) break ;;
    esac
  done

  if [[ "$PANEL_KIND" == remna && "$REMNA_ROLE" == node ]] && local_remna_panel_present; then
    REMNA_EXISTING_PANEL_SIDE_BY_SIDE=yes
    auto_done "Обнаружена локальная Remnawave-панель: включён защитный режим panel+node."
  fi

  if [[ "$PANEL_KIND" == remna && ( "$REMNA_ROLE" == panel || "$REMNA_ROLE" == both ) ]]; then
    ask_domain PANEL_DOMAIN "Домен панели Remnawave" "${PANEL_DOMAIN:-}" "panel.example.net"
    REMNA_ADMIN_USER="${REMNA_ADMIN_USER:-admin-$(openssl rand -hex 3)}"
    REMNA_ADMIN_PASS="${REMNA_ADMIN_PASS:-$(random_password)}"
  elif [[ "$PANEL_KIND" == 3xui ]]; then
    ask_optional_domain PANEL_DOMAIN "Домен HTTPS-входа в 3x-ui" "${PANEL_DOMAIN:-}" "panel.example.net"
    XUI_USER="${XUI_USER:-admin-$(openssl rand -hex 3)}"
    XUI_PASS="${XUI_PASS:-$(random_password)}"
    XUI_PANEL_PORT="${XUI_PANEL_PORT:-$((47115 + RANDOM % 1000))}"
    XUI_PATH="${XUI_PATH:-$(random_path)}"
  else
    [[ "${REMNA_EXISTING_PANEL_SIDE_BY_SIDE:-no}" == yes ]] || PANEL_DOMAIN=""
  fi

  ORIGIN_DOMAIN="${ORIGIN_DOMAIN:-}"
  CDN_DOMAIN="${CDN_DOMAIN:-}"
  case "$METHOD" in
    none)
      ORIGIN_DOMAIN=""
      CDN_DOMAIN=""
      ;;
    turboflare)
      ask_domain CDN_DOMAIN "Отдельный домен, делегированный/подключаемый к TurboFlare" "$CDN_DOMAIN" "media-example.org"
      ask_optional_domain ORIGIN_DOMAIN "Отдельный origin-домен (не обязателен: рабочий вариант TurboFlare может использовать IP:443)" "$ORIGIN_DOMAIN" "origin.example.net"
      ;;
    vk)
      ask_domain ORIGIN_DOMAIN "Origin-домен, который прямо указывает на эту ноду" "$ORIGIN_DOMAIN" "origin.example.net"
      ask_domain CDN_DOMAIN "Клиентский CDN-домен (CNAME на VK CDN)" "$CDN_DOMAIN" "cdn.example.net"
      ;;
    yandex)
      ask_domain ORIGIN_DOMAIN "Origin-домен с HTTPS-сертификатом" "$ORIGIN_DOMAIN" "origin.example.net"
      ask_domain CDN_DOMAIN "Клиентский CDN-домен Yandex" "$CDN_DOMAIN" "cdn.example.net"
      ;;
    beeline)
      ask_domain ORIGIN_DOMAIN "Origin-домен с HTTPS-сертификатом" "$ORIGIN_DOMAIN" "origin.example.net"
      echo "Технический домен Beeline вида xxx.a.trbcdn.net появится после создания ресурса."
      ask_optional_domain CDN_DOMAIN "Если он уже есть — введи технический домен" "$CDN_DOMAIN" "abc123.a.trbcdn.net"
      ;;
    timeweb)
      ask_domain CDN_DOMAIN "Клиентский домен Timeweb (CNAME на техдомен)" "$CDN_DOMAIN" "cdn.example.net"
      ORIGIN_DOMAIN=""
      ;;
    selectel)
      ask_optional_domain ORIGIN_DOMAIN "Origin-домен (Enter = использовать IP ноды)" "$ORIGIN_DOMAIN" "origin.example.net"
      echo "Технический домен Selectel вида xxxx.selcdn.net появится после создания ресурса."
      ask_optional_domain CDN_DOMAIN "Если он уже есть — введи технический домен" "$CDN_DOMAIN" "abcd.selcdn.net"
      ;;
  esac

  if [[ "$METHOD" != none ]]; then
    ask_yes_no USE_CLOUDFLARE "Использовать Cloudflare для DNS-записей там, где это применимо?" "${USE_CLOUDFLARE:-yes}"
  else
    USE_CLOUDFLARE="${USE_CLOUDFLARE:-yes}"
  fi

  if is_bare_remna_node; then
    LE_EMAIL=""
    ENABLE_UFW=no
    ask_yes_no ENABLE_BBR "Включить BBR + базовый TCP-тюнинг? (рекомендуется)" "yes"
    CASCADE=yes
    if is_side_by_side_remna_node; then
      REMNA_EXISTING_PANEL_SIDE_BY_SIDE=yes
      info "На этом VPS уже есть Remnawave-панель. Служебная нода не будет переписывать nginx/ACME/UFW панели."
    else
      REMNA_EXISTING_PANEL_SIDE_BY_SIDE=no
    fi
  else
    read -r -p "Email для Let's Encrypt (Enter = без email)${LE_EMAIL:+ [$LE_EMAIL]}: " _mail
    LE_EMAIL="${_mail:-${LE_EMAIL:-}}"
    if is_side_by_side_remna_node; then
      ENABLE_UFW=no
      danger "На этом VPS уже работает Remnawave-панель: UFW/nginx панели автоматически не переписываю."
      manual_do "Для CDN-ноды на том же VPS origin-vhost нужно добавлять отдельно и без замены panel vhost. Для каскада безопаснее выбрать 'БЕЗ CDN'."
    else
      ask_yes_no ENABLE_UFW "Настроить UFW: входящие SSH/80/443, исходящие разрешены? (рекомендуется)" "yes"
    fi
    ask_yes_no ENABLE_BBR "Включить BBR + базовый TCP-тюнинг? (рекомендуется)" "yes"
    if [[ "$METHOD" == none ]]; then
      CASCADE=no
    else
      ask_yes_no CASCADE "Нужен каскад? (CDN -> RU relay -> один или несколько foreign exit; выбор делается через --cascade)" "no"
    fi
  fi

  if [[ "$PANEL_KIND" == remna && "$REMNA_ROLE" == node ]]; then
    if [[ "$METHOD" == none ]]; then
      echo
      user_prepare "Это служебная Remnawave Node без CDN. Она нужна как relay или exit для --cascade."
      user_prepare "Сначала создай эту Node в панели. Для сервера панели + ноды на одном VPS используй публичный IP этого VPS и свободный Node Port."
      manual_do "CDN-метод, origin-домен и Host сейчас НЕ создаются — их подготовит мастер --cascade на центральной панели."
    fi
    read -r -p "IP сервера панели Remnawave: " PANEL_IP
    while ! valid_ipv4 "$PANEL_IP"; do read -r -p "Нужен IPv4 панели: " PANEL_IP; done
    echo "Node Port — это поле 'Node Port' в окне создания ноды. Он НЕ обязан быть 2222."
    ask_port REMNA_NODE_PORT "Node Port из панели Remnawave" "${REMNA_NODE_PORT:-2222}"
    read -r -s -p "SECRET_KEY ноды из панели Remnawave (ввод скрыт): " REMNA_SECRET_KEY; echo
    [[ -n "$REMNA_SECRET_KEY" ]] || die "Для node-only нужен SECRET_KEY."
  fi
  save_state
  show_config
  read -r -p "Нажми Enter, чтобы начать..." _
}

case "${1:-}" in
  --node-credentials)
    load_state || die "Нет сохранённой конфигурации ноды: $STATE_FILE"
    [[ "${PANEL_KIND:-}" == remna && ( "${REMNA_ROLE:-}" == node || "${REMNA_ROLE:-}" == both ) ]] || die "Сохранённая задача не является Remnawave-нodedой."
    echo "Обновление параметров связи Remnawave Panel → Node."
    ask_port REMNA_NODE_PORT "Node Port из карточки ноды" "${REMNA_NODE_PORT:-2222}"
    read -r -s -p "SECRET_KEY ноды: " REMNA_SECRET_KEY; echo
    [[ -n "$REMNA_SECRET_KEY" ]] || die "SECRET_KEY пустой."
    save_state
    ok "Node Port и SECRET_KEY обновлены в $STATE_FILE"
    exit 0
    ;;
  --cascade)
    run_cascade_manager
    exit 0
    ;;
  --manage-remna)
    load_state || true
    run_remna_panel_manager
    exit 0
    ;;
  --check-remna)
    if rm_panel_detected; then
      ok "Remnawave обнаружена. API: ${RM_API_BASE}. Версия образа: $(rm_panel_version || echo unknown)"
      docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|remnawave' || true
      rm_api GET /api/auth/status '' '' >/dev/null 2>&1 && ok "API отвечает через ${RM_API_BASE}" || true
    else
      die "Работающая Remnawave на этом сервере не найдена."
    fi
    exit 0
    ;;
  --update)
    info "Обновляю ${PROJECT_NAME} из публичного GitHub..."
    install -d -m 0700 "$(dirname "$INSTALL_PATH")"
    tmp_update=$(mktemp)
    curl -fsSL "${PROJECT_RAW}/install.sh" -o "$tmp_update"
    bash -n "$tmp_update"
    install -m 0700 "$tmp_update" "$INSTALL_PATH"
    rm -f "$tmp_update"
    exec "$INSTALL_PATH"
    ;;
  --version)
    echo "${PROJECT_NAME} ${INSTALLER_VERSION}"
    exit 0
    ;;
  --help|-h)
    cat <<EOF
${PROJECT_NAME} ${INSTALLER_VERSION}

Запуск: $INSTALL_PATH
Версия: $INSTALL_PATH --version
Статус: $INSTALL_PATH --status
Обновить Node Port/SECRET_KEY: $INSTALL_PATH --node-credentials
Управление существующей Remnawave: $INSTALL_PATH --manage-remna
Каскад (один exit или пул exit-нод): $INSTALL_PATH --cascade
Проверка Remnawave: $INSTALL_PATH --check-remna
Сброс ответов: $INSTALL_PATH --reset
Обновление из GitHub: $INSTALL_PATH --update
EOF
    exit 0
    ;;
  --reset-config|--reset)
    rm -f "$STATE_FILE"; rm -rf "$MARK_DIR"; mkdir -p "$MARK_DIR"
    ok "Состояние сброшено; установленные программы не удалены."
    exit 0
    ;;
  --status)
    load_state || true
    [[ -n "${PANEL_KIND:-}" && -n "${METHOD:-}" ]] && show_config || true
    [[ -f "$RESULT_FILE" ]] && { echo; cat "$RESULT_FILE"; }
    exit 0
    ;;
esac

if load_state; then
  ensure_remna_node_port
  if marked complete && [[ "${PANEL_KIND:-}" == remna ]] && [[ "${REMNA_ROLE:-}" == panel || "${REMNA_ROLE:-}" == both ]]; then
    echo
    echo "Remnawave на этом сервере уже была установлена этим скриптом."
    echo "  1 — добавить/настроить новый CDN-метод для существующей ноды"
    echo "  2 — добавить remnanode на ЭТОТ VPS без CDN (для relay/exit каскада)"
    echo "  3 — каскад: relay -> один exit / пул exit-нод"
    echo "  4 — проверить текущую установку этого сервера"
    echo "  5 — показать сохранённый результат"
    echo "  6 — начать новую задачу (сбросить только ответы установщика)"
    echo "  0 — выйти"
    read -r -p "Выбор [1]: " _done_action; _done_action="${_done_action:-1}"
    case "$_done_action" in
      1) exec "$0" --manage-remna ;;
      2)
        # Keep panel state/markers intact; only start a new node task.
        rm -f "$MARK_DIR/complete"
        PRESET="remna:none"
        PANEL_KIND=remna; REMNA_ROLE=node; METHOD=none; REMNA_EXISTING_PANEL_SIDE_BY_SIDE=yes
        collect_config
        ;;
      3) exec "$0" --cascade ;;
      4) exec "$0" --check-remna ;;
      5) [[ -f "$RESULT_FILE" ]] && cat "$RESULT_FILE"; exit 0 ;;
      6) rm -f "$STATE_FILE"; rm -rf "$MARK_DIR"; mkdir -p "$MARK_DIR"; collect_config ;;
      0) exit 0 ;;
      *) : ;;
    esac
  fi
  show_config
  echo
  echo "Enter — продолжить/проверить с сохранёнными значениями."
  echo "e     — изменить ответы (установленные программы не удалятся)."
  echo "q     — выйти."
  read -r -p "> " action
  case "${action,,}" in q) exit 0 ;; e) rm -f "$STATE_FILE"; rm -rf "$MARK_DIR"; mkdir -p "$MARK_DIR"; collect_config ;; *) : ;; esac
else
  collect_config
fi

PUBLIC_IP=""
detect_public_ip(){
  PUBLIC_IP=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)
  valid_ipv4 "$PUBLIC_IP" || PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
  valid_ipv4 "$PUBLIC_IP" || read -r -p "Публичный IPv4 VPS: " PUBLIC_IP
  info "Публичный IPv4 VPS: $PUBLIC_IP"
}
detect_public_ip

if [[ "${METHOD:-none}" != none ]]; then
  show_provider_preflight "$METHOD" "$PUBLIC_IP"
  ask_yes_no _PREP_CONTINUE "Продолжить установку после просмотра подготовки?" "yes"
  [[ "$_PREP_CONTINUE" == yes ]] || { manual_do "Установка остановлена до изменений сервера. Подготовь DNS/CDN и запусти этот же файл снова."; exit 0; }
fi

if [[ "${METHOD:-none}" == none ]]; then
  XRAY_PORT=0
  SERVER_PATH=""
  CLIENT_PATH=""
  NGINX_STYLE=""
else
  XRAY_PORT=$(method_port)
  SERVER_PATH=$(method_server_path)
  CLIENT_PATH=$(method_client_path)
  NGINX_STYLE=$(method_nginx_style)
fi

if ! marked packages; then
  info "Ставлю системные пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if is_bare_remna_node || is_side_by_side_remna_node; then
    # A node task on a VPS that already hosts the panel must never replace the
    # active reverse proxy, certificates or firewall policy.
    apt-get install -y curl jq ca-certificates openssl uuid-runtime unzip iptables dnsutils
    auto_done "Защитный node-режим: nginx/certbot/UFW и полный apt upgrade панели не трогаю."
    mark packages
  else
    apt-get upgrade -y
  # Do not install ufw together with iptables-persistent. On Ubuntu 24.04
  # (including some provider mirrors) those packages conflict, and
  # netfilter-persistent may be unavailable. We only need plain iptables;
  # persistence for the Remnawave management-port rule is handled by systemd.
  apt-get install -y nginx certbot curl jq sqlite3 ca-certificates openssl dnsutils uuid-runtime net-tools unzip iptables
  if [[ "${ENABLE_UFW:-yes}" == yes ]]; then
    # If an image already contains iptables-persistent, remove it before UFW.
    if dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q 'ok installed'; then
      warn "Удаляю iptables-persistent: он конфликтует с UFW на этой Ubuntu."
      apt-get remove -y iptables-persistent netfilter-persistent || true
    fi
    apt-get install -y ufw
  fi
  mark packages
  fi
fi

if [[ "${ENABLE_BBR:-yes}" == yes ]] && ! marked tuning; then
  info "Включаю BBR и TCP-тюнинг..."
  cat > /etc/sysctl.d/99-cdn-xhttp.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
fs.file-max = 1048576
vm.swappiness = 10
EOF
  sysctl --system >/dev/null || true
  mark tuning
fi

if ! marked swap; then
  mem_mb=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  if (( mem_mb < 3072 )) && ! swapon --show --noheadings | grep -q .; then
    info "RAM < 3 ГБ: создаю swap 2 ГБ."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  mark swap
fi

if [[ "${ENABLE_UFW:-yes}" == yes ]] && ! marked firewall; then
  info "Настраиваю UFW (только входящие правила; исходящие остаются разрешены)."
  SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2;exit}'); SSH_PORT="${SSH_PORT:-22}"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'HTTP + ACME + CDN origin'
  ufw allow 443/tcp comment 'HTTPS + CDN origin'
  ufw --force enable
  mark firewall
fi

PANEL_CERT_OK=no
ORIGIN_CERT_OK=no

if ! is_bare_remna_node && ! is_side_by_side_remna_node; then
# Placeholder and safe bootstrap nginx. The permissions below intentionally repair
# an earlier installer bug where umask 077 made ACME webroot return HTTP 403.
umask 022
install -d -m 0755 "$WEBROOT" "$ACME_ROOT" "$ACME_ROOT/.well-known" "$ACME_ROOT/.well-known/acme-challenge" "$SELF_CERT_DIR"
chmod 0755 /var/www 2>/dev/null || true

if ! marked placeholder; then
  cat > "$WEBROOT/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Технические работы</title><style>*{box-sizing:border-box}html,body{margin:0;min-height:100%;font-family:Inter,system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;background:#090d15;color:#f5f7fb}body{min-height:100vh;display:grid;place-items:center;padding:24px}.card{width:min(1080px,100%);min-height:560px;border:1px solid rgba(255,255,255,.09);border-radius:30px;overflow:hidden;background:#141b29;box-shadow:0 40px 120px rgba(0,0,0,.48);position:relative}.text{position:relative;z-index:1;max-width:720px;padding:90px 70px}.badge{display:inline-block;padding:8px 12px;border:1px solid rgba(244,177,68,.35);background:rgba(244,177,68,.12);border-radius:999px;color:#ffc966;font-size:13px;font-weight:750;letter-spacing:.08em;text-transform:uppercase}h1{font-size:clamp(42px,7vw,76px);line-height:.98;letter-spacing:-.045em;margin:24px 0 22px}p{max-width:580px;color:#b9c3d3;font-size:clamp(17px,2vw,21px);line-height:1.6;margin:0}.small{margin-top:34px;color:#788398;font-size:13px}</style></head><body><main class="card"><section class="text"><span class="badge">Обновление сервиса</span><h1>Идут технические работы</h1><p>Мы обновляем систему и скоро вернёмся. Спасибо за понимание.</p><div class="small">Попробуйте зайти немного позже.</div></section></main></body></html>
HTML
  chmod 0644 "$WEBROOT/index.html"
  mark placeholder
fi

if [[ ! -s "$SELF_CERT_DIR/server.crt" || ! -s "$SELF_CERT_DIR/server.key" ]]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$SELF_CERT_DIR/server.key" -out "$SELF_CERT_DIR/server.crt" -subj "/CN=cdn-origin" >/dev/null 2>&1
  chmod 600 "$SELF_CERT_DIR/server.key"
fi

write_bootstrap_nginx(){
  info "Готовлю безопасный nginx bootstrap до Certbot..."
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  if nginx_foreign_enabled_sites; then
    danger "В /etc/nginx/sites-enabled найдены чужие/неизвестные vhost. Автоматически очищать каталог нельзя."
    find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -printf '  - %f\n' >&2 2>/dev/null || true
    die "Bootstrap nginx остановлен ДО изменений. Используй чистый VPS или перенеси/объедини существующие vhost вручную."
  fi
  cp -a /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  mkdir -p "$BACKUP_DIR/sites-enabled-before-bootstrap"
  cp -a /etc/nginx/sites-enabled/. "$BACKUP_DIR/sites-enabled-before-bootstrap/" 2>/dev/null || true
  find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cat > /etc/nginx/sites-available/cdn-bootstrap.conf <<EOF
# panel-script-v1 bootstrap
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ {
        alias ${ACME_ROOT}/.well-known/acme-challenge/;
        default_type text/plain;
    }
    location / { root ${WEBROOT}; try_files \$uri /index.html; }
}
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    ssl_certificate ${SELF_CERT_DIR}/server.crt;
    ssl_certificate_key ${SELF_CERT_DIR}/server.key;
    location / { root ${WEBROOT}; try_files \$uri /index.html; }
}
EOF
  ln -sfn /etc/nginx/sites-available/cdn-bootstrap.conf /etc/nginx/sites-enabled/cdn-bootstrap.conf
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

# v1.0.1 marked bootstrap_nginx before validating ACME. Always validate again;
# if the marker is stale, recreate the bootstrap automatically.
if ! marked bootstrap_nginx; then
  write_bootstrap_nginx
fi

acme_probe(){
  local host="$1" url="$2" code body
  code=$(curl --noproxy '*' -sS --max-time 5 -o /tmp/acme-body -w '%{http_code}' -H "Host: ${host}" "$url" 2>/dev/null || true)
  body=$(cat /tmp/acme-body 2>/dev/null || true)
  rm -f /tmp/acme-body
  [[ "$code" == 200 && "$body" == "$ACME_TEST" ]]
}

ACME_TEST="acme-$(openssl rand -hex 5)"
printf '%s\n' "$ACME_TEST" > "$ACME_ROOT/.well-known/acme-challenge/$ACME_TEST"
chmod 0644 "$ACME_ROOT/.well-known/acme-challenge/$ACME_TEST"

ACME_OK=no
if acme_probe acme-test.invalid "http://127.0.0.1/.well-known/acme-challenge/$ACME_TEST"; then
  ACME_OK=yes
  ok "ACME webroot через loopback работает (200)."
else
  warn "Loopback-проверка ACME не дала 200; проверяю публичный IPv4 интерфейс."
  if acme_probe acme-test.invalid "http://${PUBLIC_IP}/.well-known/acme-challenge/$ACME_TEST"; then
    ACME_OK=yes
    ok "ACME webroot через публичный IPv4 работает (200)."
  fi
fi

if [[ "$ACME_OK" != yes ]]; then
  warn "Пересоздаю bootstrap nginx: возможно, остался маркер от v1.0.1."
  rm -f "$MARK_DIR/bootstrap_nginx"
  write_bootstrap_nginx
  if acme_probe acme-test.invalid "http://127.0.0.1/.well-known/acme-challenge/$ACME_TEST" ||      acme_probe acme-test.invalid "http://${PUBLIC_IP}/.well-known/acme-challenge/$ACME_TEST"; then
    ACME_OK=yes
  fi
fi

if [[ "$ACME_OK" != yes ]]; then
  echo "--- nginx listeners ---" >&2
  ss -ltnp | grep -E ':(80|443)\b' >&2 || true
  echo "--- active nginx ACME/listen lines ---" >&2
  nginx -T 2>&1 | grep -nE 'panel-script-v1 bootstrap|listen .*80|server_name|acme-challenge' | tail -n 80 >&2 || true
  rm -f "$ACME_ROOT/.well-known/acme-challenge/$ACME_TEST"
  die "nginx не отдаёт ACME webroot ни через loopback, ни через публичный IPv4. Диагностика напечатана выше."
fi

rm -f "$ACME_ROOT/.well-known/acme-challenge/$ACME_TEST"
mark bootstrap_nginx

resolve_v4(){ dig +short A "$1" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 || true; }
certbot_for_domain(){
  local domain="$1" certname="$2" ip
  [[ -n "$domain" ]] || return 1
  ip=$(resolve_v4 "$domain")
  if [[ "$ip" != "$PUBLIC_IP" ]]; then warn "$domain -> ${ip:-нет A-записи}; LE пока пропускаю. Домен должен прямо указывать на $PUBLIC_IP во время HTTP-01."; return 1; fi
  local args=(certonly --webroot -w "$ACME_ROOT" -d "$domain" --cert-name "$certname" --non-interactive --agree-tos --keep-until-expiring)
  [[ -n "${LE_EMAIL:-}" ]] && args+=(--email "$LE_EMAIL" --no-eff-email) || args+=(--register-unsafely-without-email)
  certbot "${args[@]}" || return 1
  [[ -s "/etc/letsencrypt/live/$certname/fullchain.pem" ]]
}

PANEL_CERT_OK=no
if [[ -n "${PANEL_DOMAIN:-}" ]]; then
  [[ -s /etc/letsencrypt/live/cdn-panel/fullchain.pem ]] && PANEL_CERT_OK=yes || certbot_for_domain "$PANEL_DOMAIN" cdn-panel && PANEL_CERT_OK=yes || true
fi
ORIGIN_CERT_OK=no
if [[ -n "${ORIGIN_DOMAIN:-}" ]]; then
  [[ -s /etc/letsencrypt/live/cdn-origin/fullchain.pem ]] && ORIGIN_CERT_OK=yes || certbot_for_domain "$ORIGIN_DOMAIN" cdn-origin && ORIGIN_CERT_OK=yes || true
fi
else
  if is_side_by_side_remna_node; then
    info "Защитный режим panel+node: существующий nginx/ACME панели не изменяю и bootstrap не включаю."
  else
    info "Служебная нода без CDN: существующий nginx/ACME на сервере не изменяю."
  fi
fi

install_docker(){
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && return 0
  curl -fsSL https://get.docker.com | sh
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
}

install_remna_panel(){
  marked remna_panel && return 0
  if local_remna_panel_present; then
    die "На диске/в Docker уже обнаружена Remnawave-панель. Автопереустановка и перезапись /opt/remnawave/.env заблокированы; используй режим существующей панели."
  fi
  install_docker
  local app_secret pg_pass metrics_pass webhook
  app_secret=$(openssl rand -hex 64); pg_pass=$(openssl rand -hex 24); metrics_pass=$(openssl rand -hex 16); webhook=$(openssl rand -hex 32)
  mkdir -p /opt/remnawave
  cat > /opt/remnawave/docker-compose.yml <<EOF
services:
  remnawave-db:
    container_name: remnawave-db
    image: postgres:17
    restart: always
    shm_size: 256m
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${pg_pass}
    volumes:
      - remnawave-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s
      timeout: 3s
      retries: 20
    networks: [remnawave-network]
  remnawave-redis:
    container_name: remnawave-redis
    image: valkey/valkey:8.1.1-alpine
    restart: always
    command: valkey-server --save 20 1
    volumes:
      - remnawave-redis:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 3s
      timeout: 3s
      retries: 20
    networks: [remnawave-network]
  remnawave:
    container_name: remnawave
    image: remnawave/backend:${REMNA_VERSION}
    restart: always
    ports:
      - "127.0.0.1:3000:3000"
    env_file: [.env]
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    networks: [remnawave-network]
volumes:
  remnawave-db:
  remnawave-redis:
networks:
  remnawave-network:
    driver: bridge
EOF
  cat > /opt/remnawave/.env <<EOF
APP_SECRET=${app_secret}
METRICS_USER=metrics
METRICS_PASS=${metrics_pass}
WEBHOOK_SECRET_HEADER=${webhook}
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=postgres
DATABASE_URL="postgresql://postgres:${pg_pass}@remnawave-db:5432/postgres"
REDIS_HOST=remnawave-redis
REDIS_PORT=6379
FRONT_END_DOMAIN=${PANEL_DOMAIN}
PANEL_DOMAIN=${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=${PANEL_DOMAIN}/api/sub
IS_PANEL_BEHIND_CLOUDFLARE=false
TRAFFIC_RESET_DAY=1
EOF
  chmod 600 /opt/remnawave/.env
  (cd /opt/remnawave && docker compose pull && docker compose up -d)
  for _ in {1..60}; do curl -sS --max-time 2 http://127.0.0.1:3000 >/dev/null 2>&1 && break; sleep 2; done
  docker ps --format '{{.Names}} {{.Status}}' | grep -E '^remnawave(-db|-redis)? ' || true
  mark remna_panel
}

xray_zip_name(){ case "$(uname -m)" in aarch64|arm64) echo Xray-linux-arm64-v8a.zip ;; *) echo Xray-linux-64.zip ;; esac; }
download_xray(){
  local dest="$1" version="$2" zip
  zip=$(xray_zip_name)
  mkdir -p "$(dirname "$dest")" /tmp/xray_dl
  rm -rf /tmp/xray_dl/* /tmp/xray.zip
  curl -fL --retry 3 --connect-timeout 20 -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${version}/${zip}" \
    || curl -fL --retry 3 -o /tmp/xray.zip "https://gh-proxy.com/https://github.com/XTLS/Xray-core/releases/download/v${version}/${zip}"
  unzip -o /tmp/xray.zip xray -d /tmp/xray_dl >/dev/null
  install -m 0755 /tmp/xray_dl/xray "$dest"
  # Do not pipe to `head` under `set -o pipefail`: Xray writes several lines,
  # `head` closes early and Xray exits with SIGPIPE (141), aborting the installer.
  "$dest" version 2>&1 | sed -n '1p'
}

install_remna_node(){
  if marked remna_node; then
    if docker inspect remnanode >/dev/null 2>&1; then
      return 0
    fi
    warn "Маркер remna_node есть, но контейнер remnanode не найден — восстанавливаю ноду."
    rm -f "$MARK_DIR/remna_node"
  fi
  ensure_remna_node_port
  install_docker

  if docker inspect remnanode >/dev/null 2>&1; then
    danger "Контейнер remnanode уже существует, но не принадлежит текущей незавершённой задаче установщика."
    manual_do "Его .env/SECRET_KEY автоматически НЕ перезаписываются. Для изменения связи используй --node-credentials."
    return 0
  fi
  if ss -ltnp 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$REMNA_NODE_PORT$"; then
    die "Node Port $REMNA_NODE_PORT уже занят. Выбери другой свободный порт в карточке Node и повтори установку."
  fi
  mkdir -p /opt/remnanode
  download_xray /opt/remnanode/xray-custom "$XRAY_MANUAL_VERSION"

  if [[ "$REMNA_ROLE" == both ]]; then
    REMNA_ADMIN_USER="${REMNA_ADMIN_USER:-admin-$(openssl rand -hex 3)}"
    REMNA_ADMIN_PASS="${REMNA_ADMIN_PASS:-$(random_password)}"
    echo
    warn "Нужен SECRET_KEY ноды из только что установленной панели."
    echo "Открой https://${PANEL_DOMAIN}/, зарегистрируй первого администратора."
    echo "Скрипт НЕ создаёт администратора Remnawave и НЕ меняет его пароль."
    echo "Если хочешь, можешь использовать эти СГЕНЕРИРОВАННЫЕ ПОДСКАЗКИ при ручной регистрации:"
    echo "  Предложенный логин:  $REMNA_ADMIN_USER"
    echo "  Предложенный пароль: $REMNA_ADMIN_PASS"
    echo "Если введёшь другие данные в веб-интерфейсе, именно они будут реальными."
    echo "Потом: Nodes → Create node → Address=$PUBLIC_IP → Port=${REMNA_NODE_PORT} → скопируй SECRET_KEY."
    read -r -p "SECRET_KEY: " REMNA_SECRET_KEY
    [[ -n "$REMNA_SECRET_KEY" ]] || die "SECRET_KEY пустой."
    PANEL_IP="$PUBLIC_IP"
    save_state
  fi

  cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:${REMNA_VERSION}
    network_mode: host
    restart: always
    cap_add: [NET_ADMIN]
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - /opt/remnanode/xray-custom:/usr/local/bin/xray:ro
    env_file: [.env]
EOF
  cat > /opt/remnanode/.env <<EOF
NODE_PORT=${REMNA_NODE_PORT}
SECRET_KEY=${REMNA_SECRET_KEY}
EOF
  chmod 600 /opt/remnanode/.env
  (cd /opt/remnanode && docker compose pull && docker compose up -d)
  sleep 3
  docker logs remnanode --tail=30 || true

  # Restrict management port. Docker host-network listener must not be public.
  # Do not depend on iptables-persistent/netfilter-persistent: they conflict
  # with UFW on some Ubuntu 24.04 images. A small idempotent systemd service
  # restores only our dedicated chain after every reboot.
  cat > /usr/local/sbin/panel-script-v1-remna-firewall <<EOF
#!/usr/bin/env bash
set -e
CHAIN=PSV1_REMNA_NODE
iptables -N "\$CHAIN" 2>/dev/null || true
iptables -F "\$CHAIN"
iptables -A "\$CHAIN" -s ${PANEL_IP} -j ACCEPT
iptables -A "\$CHAIN" -s 127.0.0.1 -j ACCEPT
iptables -A "\$CHAIN" -s 172.16.0.0/12 -j ACCEPT
iptables -A "\$CHAIN" -j DROP
iptables -C INPUT -p tcp --dport ${REMNA_NODE_PORT} -j "\$CHAIN" 2>/dev/null || iptables -I INPUT 1 -p tcp --dport ${REMNA_NODE_PORT} -j "\$CHAIN"
EOF
  chmod 0700 /usr/local/sbin/panel-script-v1-remna-firewall

  cat > /etc/systemd/system/panel-script-v1-remna-firewall.service <<'EOF'
[Unit]
Description=panel-script-v1 Remnawave node firewall
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/panel-script-v1-remna-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now panel-script-v1-remna-firewall.service
  mark remna_node
}

install_xui(){
  marked xui && return 0
  if [[ -r /etc/x-ui/x-ui.db && -x /usr/local/x-ui/x-ui ]]; then
    XUI_EXISTING=yes
    warn "3x-ui уже установлена; переустанавливать и менять её существующие логин/пароль/порт не буду."
    warn "Автосоздание inbound может попросить ручной импорт, если установщик не знает текущий пароль."
    save_state
  else
    XUI_EXISTING=no
    info "Устанавливаю 3x-ui $XUI_VERSION в compatibility-режиме..."
    tmp=$(mktemp)
    curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh -o "$tmp"
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite XUI_SERVER_IP="$PUBLIC_IP" bash "$tmp" "$XUI_VERSION" || {
      warn "Non-interactive режим не сработал. Запускаю официальный installer интерактивно; выбирай SQLite и без встроенного SSL."
      bash "$tmp" "$XUI_VERSION"
    }
    rm -f "$tmp"
    [[ -r /etc/x-ui/x-ui.db ]] || die "3x-ui: нет /etc/x-ui/x-ui.db."
    /usr/local/x-ui/x-ui setting -username "$XUI_USER" -password "$XUI_PASS" -port "$XUI_PANEL_PORT" -webBasePath "/$XUI_PATH/" || true
    systemctl restart x-ui; sleep 2
    save_state
  fi
  [[ -r /etc/x-ui/x-ui.db ]] || die "3x-ui: нет /etc/x-ui/x-ui.db."
  mark xui
}

upgrade_xui_xray(){
  [[ "${UPGRADE_XUI_XRAY:-no}" == yes ]] || return 0
  marked xui_xray && return 0
  local bin
  bin=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 | head -1 || true)
  [[ -n "$bin" ]] || die "Не нашёл бинарник Xray 3x-ui."
  cp -a "$bin" "$bin.backup.$(date +%Y%m%d-%H%M%S)"
  systemctl stop x-ui
  download_xray "$bin" "$XRAY_MANUAL_VERSION"
  systemctl start x-ui; sleep 2
  mark xui_xray
}

xui_stream_json(){
  local cdn="$CDN_DOMAIN"
  [[ -n "$cdn" ]] || cdn="CHANGE-CDN-DOMAIN.example"
  if [[ "$METHOD" == yandex ]]; then
    jq -n --arg cdn "$cdn" --arg path "$SERVER_PATH" '{network:"xhttp",security:"none",externalProxy:[{forceTls:"tls",dest:$cdn,port:443,remark:"CDN",sni:$cdn,fingerprint:"firefox",alpn:["h2","http/1.1"]}],xhttpSettings:{path:$path,host:"",mode:"packet-up",xPaddingBytes:"100-1000",xPaddingObfsMode:true,xPaddingKey:"hash",xPaddingHeader:"X-Client-Version",xPaddingPlacement:"query",xPaddingMethod:"tokenish",uplinkHTTPMethod:"GET",uplinkDataPlacement:"body",uplinkChunkSize:131072,noSSEHeader:false,scMaxEachPostBytes:"500000-1000000",scMinPostsIntervalMs:"50-150",scStreamUpServerSecs:"60-180",enableXmux:true,xmux:{maxConcurrency:"16-32",maxConnections:0,cMaxReuseTimes:1000,hMaxRequestTimes:"600-900",hMaxReusableSecs:"100",hKeepAlivePeriod:20000}}}'
  else
    jq -n --arg cdn "$cdn" --arg path "$SERVER_PATH" '{network:"xhttp",security:"none",externalProxy:[{forceTls:"tls",dest:$cdn,port:443,remark:"CDN",sni:$cdn,fingerprint:"firefox",alpn:["h2","http/1.1"]}],xhttpSettings:{path:$path,host:"",mode:"packet-up",xPaddingBytes:"100-1000",xPaddingObfsMode:true,xPaddingKey:"hash",xPaddingHeader:"X-Client-Version",xPaddingPlacement:"query",xPaddingMethod:"tokenish",uplinkHTTPMethod:"GET",uplinkDataPlacement:"body",noSSEHeader:false,scMaxEachPostBytes:"500000-1000000",scMinPostsIntervalMs:"50-150",scStreamUpServerSecs:"60-180",enableXmux:true,xmux:{maxConcurrency:"16-32",maxConnections:0,cMaxReuseTimes:1000,hMaxRequestTimes:"600-900",hMaxReusableSecs:"100",hKeepAlivePeriod:20000}}}'
  fi
}

xui_create_inbound(){
  marked xui_inbound && return 0
  local uuid sub stream payload base cookie login list iid resp
  uuid=$(uuidgen | tr 'A-Z' 'a-z'); sub=$(openssl rand -hex 8); stream=$(xui_stream_json)
  payload=$(jq -n --arg remark "$(method_title "$METHOD") CDN XHTTP" --arg tag "${METHOD}-cdn-xhttp" --argjson port "$XRAY_PORT" --argjson stream "$stream" --arg uuid "$uuid" --arg sub "$sub" '{enable:true,remark:$remark,tag:$tag,listen:"127.0.0.1",port:$port,protocol:"vless",expiryTime:0,total:0,settings:{clients:[{id:$uuid,email:"first-user",flow:"",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}],decryption:"none",encryption:"none",fallbacks:[]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}}')
  printf '%s\n' "$payload" > "$OUT_DIR/3xui-inbound.json"; chmod 600 "$OUT_DIR/3xui-inbound.json"

  base="http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_PATH}"
  cookie=/tmp/xui-cookie.$$
  login=$(curl -sS --max-time 10 -c "$cookie" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "username=$XUI_USER" --data-urlencode "password=$XUI_PASS" "$base/login" 2>/dev/null || true)
  if ! echo "$login" | jq -e '.success==true' >/dev/null 2>&1; then
    warn "Не удалось войти в локальный API 3x-ui автоматически. Готовый inbound сохранён: $OUT_DIR/3xui-inbound.json"
    warn "Создай/импортируй inbound в панели вручную; External Proxy уже включён в JSON."
    rm -f "$cookie"; mark xui_inbound; return 0
  fi
  list=$(curl -sS --max-time 10 -b "$cookie" "$base/panel/api/inbounds/list" 2>/dev/null || true)
  iid=$(echo "$list" | jq -r --argjson p "$XRAY_PORT" '[.obj[]? | select(.port==$p and .protocol=="vless") | .id][0] // empty')
  if [[ "$iid" =~ ^[0-9]+$ ]]; then
    resp=$(curl -sS --max-time 20 -b "$cookie" -H 'Content-Type: application/json' -X POST --data-binary "$payload" "$base/panel/api/inbounds/update/$iid" 2>/dev/null || true)
  else
    resp=$(curl -sS --max-time 20 -b "$cookie" -H 'Content-Type: application/json' -X POST --data-binary "$payload" "$base/panel/api/inbounds/add" 2>/dev/null || true)
  fi
  rm -f "$cookie"
  if echo "$resp" | jq -e '.success==true' >/dev/null 2>&1; then ok "3x-ui inbound создан/обновлён автоматически."; else warn "API не принял inbound: ${resp:-нет ответа}"; warn "Используй файл $OUT_DIR/3xui-inbound.json вручную."; fi
  mark xui_inbound
}

remna_default_tag(){
  case "$METHOD" in
    vk) echo "cdn-stream" ;;
    yandex) echo "yasha" ;;
    beeline) echo "cdn-beeline" ;;
    timeweb) echo "cdn-timeweb" ;;
    selectel) echo "cdn-selectel" ;;
    turboflare) echo "cdn-turboflare" ;;
  esac
}

remna_inbound_json(){
  rm_method_inbound_json "$METHOD" "$(remna_default_tag)"
}

remna_host_extra_json(){
  local inbound
  inbound=$(remna_inbound_json)
  rm_method_host_extra_json "$METHOD" "$inbound"
}

remna_host_values(){
  local alpn fp addr
  addr="$CDN_DOMAIN"
  case "$METHOD" in
    vk) alpn="h2"; fp="firefox" ;;
    yandex) alpn="h3,h2,http/1.1"; fp="random" ;;
    beeline) alpn="h2"; fp="firefox" ;;
    timeweb) alpn="h2,http/1.1"; fp="random" ;;
    selectel) alpn="h2"; fp="random" ;;
    turboflare) alpn="h2,http/1.1"; fp="firefox" ;;
  esac
  cat <<EOF
Address: ${addr:-<введи CDN-домен после создания ресурса>}
SNI/Host: ${addr:-<тот же CDN-домен>}
Port: 443
Path: ${CLIENT_PATH}
ALPN: ${alpn}
Fingerprint: ${fp}
Security: TLS
Inbound port/tag: ${XRAY_PORT}
EOF
}

generate_remna_templates(){
  local inbound extra dns
  inbound=$(remna_inbound_json); extra=$(remna_host_extra_json)
  if [[ "$METHOD" == yandex ]]; then dns='{"queryStrategy":"UseIPv4","servers":[{"address":"8.8.8.8","skipFallback":false}]}' ; else dns='{"queryStrategy":"UseIPv4","servers":[{"address":"1.1.1.1","skipFallback":false},{"address":"1.0.0.1","skipFallback":false}]}' ; fi
  jq -n --argjson inbound "$inbound" --argjson dns "$dns" '{log:{loglevel:"warning"},dns:$dns,inbounds:[$inbound],outbounds:[{tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"BLOCK",protocol:"blackhole"}],routing:{domainStrategy:"IPIfNonMatch",rules:[{type:"field",ip:["geoip:private"],outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}' > "$OUT_DIR/remnawave-profile-${METHOD}.json"
  printf '%s\n' "$extra" | jq . > "$OUT_DIR/remnawave-host-extra-${METHOD}.json"
  remna_host_values > "$OUT_DIR/remnawave-host-${METHOD}.txt"
  chmod 600 "$OUT_DIR"/*
}

write_remna_panel_only_nginx(){
  local panel_cert="$SELF_CERT_DIR/server.crt" panel_key="$SELF_CERT_DIR/server.key"
  [[ "$PANEL_CERT_OK" == yes ]] && { panel_cert="/etc/letsencrypt/live/cdn-panel/fullchain.pem"; panel_key="/etc/letsencrypt/live/cdn-panel/privkey.pem"; }

  cp -a /etc/nginx/sites-available "$BACKUP_DIR/sites-available.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  cat > /etc/nginx/sites-available/remnawave-panel.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; default_type text/plain; }
    location / { return 301 https://${PANEL_DOMAIN}\$request_uri; }
}
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name ${PANEL_DOMAIN} _;
    ssl_certificate ${panel_cert};
    ssl_certificate_key ${panel_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  rm -f /etc/nginx/sites-enabled/cdn-bootstrap.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/cdn-origin.conf
  ln -sfn /etc/nginx/sites-available/remnawave-panel.conf /etc/nginx/sites-enabled/remnawave-panel.conf
  nginx -t
  systemctl reload nginx
  mark final_nginx
}

write_nginx(){
  if is_side_by_side_remna_node; then
    if [[ "$METHOD" == none ]]; then
      auto_done "Panel+node safe mode: активные nginx vhost панели оставлены без изменений."
    else
      danger "Panel+node safe mode: CDN origin nginx НЕ включён автоматически, чтобы не заменить рабочий vhost/сертификат панели."
      manual_do "Используй отдельный origin-домен и добавь отдельный server_name в существующий nginx вручную либо вынеси relay/CDN-ноду на отдельный VPS."
    fi
    return 0
  fi
  if [[ "$PANEL_KIND" == remna && "$METHOD" == none ]]; then
    if [[ "$REMNA_ROLE" == panel || "$REMNA_ROLE" == both ]]; then
      write_remna_panel_only_nginx
    else
      info "Нода без CDN: nginx не меняю. Для relay reverse proxy/Caddy настраивается позже через --cascade."
    fi
    return 0
  fi
  if [[ "$PANEL_KIND" == remna && "$REMNA_ROLE" == panel ]]; then
    write_remna_panel_only_nginx
    return 0
  fi
  local cert="$SELF_CERT_DIR/server.crt" key="$SELF_CERT_DIR/server.key"
  [[ "$ORIGIN_CERT_OK" == yes ]] && { cert="/etc/letsencrypt/live/cdn-origin/fullchain.pem"; key="/etc/letsencrypt/live/cdn-origin/privkey.pem"; }
  local panel_cert="$SELF_CERT_DIR/server.crt" panel_key="$SELF_CERT_DIR/server.key"
  [[ "$PANEL_CERT_OK" == yes ]] && { panel_cert="/etc/letsencrypt/live/cdn-panel/fullchain.pem"; panel_key="/etc/letsencrypt/live/cdn-panel/privkey.pem"; }

  if [[ "$METHOD" == selectel ]]; then
    if ! grep -q 'large_client_header_buffers 8 64k;' /etc/nginx/nginx.conf; then sed -i '/http {/a\\    large_client_header_buffers 8 64k;' /etc/nginx/nginx.conf; fi
  fi

  cp -a /etc/nginx/sites-available "$BACKUP_DIR/sites-available.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  cat > /etc/nginx/sites-available/cdn-origin.conf <<EOF
upstream xray_xhttp { server 127.0.0.1:${XRAY_PORT}; keepalive 128; }
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; default_type text/plain; }
    location = /health { default_type application/json; return 200 '{"status":"ok","service":"media-gateway"}'; }
EOF
  if [[ "$NGINX_STYLE" == rewrite ]]; then
    cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
    location ^~ ${SERVER_PATH} {
        rewrite ^/static/getFile/video/segment\\.ts\$ /static/getFile/video/segment.ts/ break;
EOF
  else
    local noslash="${SERVER_PATH%/}"
    cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
    location = ${noslash} { return 404; }
    location ${SERVER_PATH} {
EOF
  fi
  cat >> /etc/nginx/sites-available/cdn-origin.conf <<'EOF'
        proxy_pass http://xray_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_pass_request_headers on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_max_temp_file_size 0;
        gzip off;
        proxy_connect_timeout 10s;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        send_timeout 1h;
        client_max_body_size 0;
        proxy_socket_keepalive on;
        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-cache" always;
        add_header CDN-Cache-Control "no-store" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        add_header Accept-Ranges none always;
    }
    location / { root /var/www/cdn-placeholder; index index.html; try_files $uri $uri/ /index.html; }
}
EOF

  cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; default_type text/plain; }
    location = /health { default_type application/json; return 200 '{"status":"ok","service":"media-gateway"}'; }
EOF
  if [[ "$NGINX_STYLE" == rewrite ]]; then
    cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
    location ^~ ${SERVER_PATH} {
        rewrite ^/static/getFile/video/segment\\.ts\$ /static/getFile/video/segment.ts/ break;
EOF
  else
    local noslash2="${SERVER_PATH%/}"
    cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
    location = ${noslash2} { return 404; }
    location ${SERVER_PATH} {
EOF
  fi
  cat >> /etc/nginx/sites-available/cdn-origin.conf <<'EOF'
        proxy_pass http://xray_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass_request_headers on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_max_temp_file_size 0;
        gzip off;
        proxy_connect_timeout 10s;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        send_timeout 1h;
        client_max_body_size 0;
        proxy_socket_keepalive on;
        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-cache" always;
        add_header CDN-Cache-Control "no-store" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        add_header Accept-Ranges none always;
    }
    location / { root /var/www/cdn-placeholder; index index.html; try_files $uri $uri/ /index.html; }
}
EOF

  if [[ "$PANEL_KIND" == 3xui ]]; then
    # Add panel path to the default HTTPS server by creating a dedicated named vhost when domain exists;
    # by IP, panel stays reachable on its local port only through SSH unless PANEL_DOMAIN is provided.
    if [[ -n "$PANEL_DOMAIN" ]]; then
      cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PANEL_DOMAIN};
    ssl_certificate ${panel_cert};
    ssl_certificate_key ${panel_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location ^~ /${XUI_PATH}/ {
        proxy_pass http://127.0.0.1:${XUI_PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    location / { root ${WEBROOT}; try_files \$uri /index.html; }
}
EOF
    fi
  elif [[ "$PANEL_KIND" == remna && ( "$REMNA_ROLE" == panel || "$REMNA_ROLE" == both ) ]]; then
    cat >> /etc/nginx/sites-available/cdn-origin.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PANEL_DOMAIN};
    ssl_certificate ${panel_cert};
    ssl_certificate_key ${panel_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  fi

  rm -f /etc/nginx/sites-enabled/cdn-bootstrap.conf /etc/nginx/sites-enabled/default
  find /etc/nginx/sites-enabled -maxdepth 1 -type l -name 'cdn-origin.conf' -delete 2>/dev/null || true
  ln -sfn /etc/nginx/sites-available/cdn-origin.conf /etc/nginx/sites-enabled/cdn-origin.conf
  nginx -t; systemctl reload nginx
  mark final_nginx
}

provider_steps(){
  [[ "$METHOD" == none ]] && return 0
  local f="$OUT_DIR/provider-steps-${METHOD}.txt"
  {
    echo "$(method_title "$METHOD") — настройки CDN-ресурса"
    echo "================================================"
    if [[ "${USE_CLOUDFLARE:-yes}" == yes ]]; then
      echo "DNS: Cloudflare = ДА; A/CNAME создавать как DNS only."
    else
      echo "DNS: Cloudflare = НЕТ; записи создать у текущего DNS-провайдера без proxy/CDN."
    fi
    echo
    case "$METHOD" in
      turboflare)
        echo "ВАЖНО: найденное нами на практике обязательное поле:"
        echo "TurboFlare → Сайты → твой домен → Редактирование:"
        echo "  Адрес: ${PUBLIC_IP}:443"
        echo "  Использовать HTTPS при запросе к источникам: ВКЛ"
        echo "  Обслуживать устаревший кэш при недоступности источника: ВЫКЛ"
        echo "  Сохранить."
        echo
        echo "После делегирования CDN-домен НЕ обязан резолвиться в VPS — он должен резолвиться в edge TurboFlare."
        echo "IP VPS задаётся именно в поле Адрес источника выше."
        echo "NS у регистратора: ns1-c.trbcdn.net / ns2-c.trbcdn.net / ns3-c.trbcdn.net"
        echo "Кэш XHTTP: выключить; query-параметры учитывать."
        ;;
      vk)
        echo "Источник: ${ORIGIN_DOMAIN}:80 по HTTP; персональный домен ${CDN_DOMAIN}; Host пересылать."
        echo "Кэширование: все переключатели ВЫКЛ; методы GET/HEAD/OPTIONS; gzip ВЫКЛ."
        echo "После создания: CNAME ${CDN_DOMAIN} → CNAME, который выдаст VK; DNS only."
        ;;
      yandex)
        echo "Источник: ${ORIGIN_DOMAIN}, HTTPS; SNI вручную=${ORIGIN_DOMAIN}; Host=${ORIGIN_DOMAIN}."
        echo "Для ${CDN_DOMAIN} выпустить сертификат в Certificate Manager (DNS validation)."
        echo "Кэш CDN и браузера ВЫКЛ; query НЕ игнорировать; compression ВЫКЛ; проверку сертификата origin ВЫКЛ."
        ;;
      beeline)
        echo "panel.cdnvideo.ru: тип Статика; origin ${ORIGIN_DOMAIN}:443; HTTPS ВКЛ; verify cert ВЫКЛ; SNI=${ORIGIN_DOMAIN}."
        echo "Передавать исходный Host ВКЛ; cache всех классов не кешировать; query учитывать ВСЕ."
        echo "Экспертный rewrite: ${SERVER_PATH}/ -> ${SERVER_PATH}; HTTP2 ВКЛ; HTTP3 ВЫКЛ; HTTP→HTTPS ВКЛ."
        echo "После создания скопировать технический домен xxx.a.trbcdn.net — он идёт в ключ."
        ;;
      timeweb)
        echo "Источник строго: ${PUBLIC_IP}:80 (вкладка IP-адрес); HTTPS ВЫКЛ."
        echo "Кэш ВЫКЛ; 'Игнорировать параметры запроса' строго ВЫКЛ."
        echo "Добавить домен ${CDN_DOMAIN}; CNAME на xxx.cdn.twcstorage.ru; затем выпустить LE после статуса Активен."
        ;;
      selectel)
        echo "Тип Статика; источник ${ORIGIN_DOMAIN:-$PUBLIC_IP}; кэш ВЫКЛ; gzip ВЫКЛ; игнорировать query ВЫКЛ."
        echo "Проверка сертификата origin ВЫКЛ; в разрешённые методы добавить POST."
        echo "Таймауты origin: connect=30, send=9999, receive=9999."
        echo "Технический xxxx.selcdn.net идёт в ключ."
        ;;
    esac
    echo
    echo "После активации проверка: curl к CDN path должен дать HTTP 400."
  } > "$f"
  chmod 600 "$f"
  print_manual_file_colored "$f"
}

# Install panel/node before writing final nginx where possible.
if [[ "$PANEL_KIND" == remna ]]; then
  if [[ "$REMNA_ROLE" == panel || "$REMNA_ROLE" == both ]]; then
    install_remna_panel
    # Для panel+node панель должна открыться до создания ноды и получения SECRET_KEY.
    [[ "$REMNA_ROLE" == both ]] && write_nginx
  fi
  if [[ "$REMNA_ROLE" == node || "$REMNA_ROLE" == both ]]; then
    install_remna_node
    if [[ "$METHOD" != none ]]; then
      generate_remna_templates
    else
      auto_done "Remnawave Node установлена без CDN-профиля; каскад настроится позже через --cascade."
    fi
  fi
else
  install_xui
  upgrade_xui_xray
  xui_create_inbound
fi

write_nginx
[[ "$METHOD" != none ]] && provider_steps

# If provider gives its tech domain only after resource creation, collect it now.
if [[ -z "${CDN_DOMAIN:-}" && ( "$METHOD" == beeline || "$METHOD" == selectel ) ]]; then
  echo
  read -r -p "Введи технический CDN-домен после создания ресурса (Enter = пропустить до следующего запуска): " cdnnew
  if [[ -n "$cdnnew" ]]; then
    valid_domain "$cdnnew" || die "Некорректный CDN-домен."
    CDN_DOMAIN="${cdnnew,,}"; save_state
    [[ "$PANEL_KIND" == remna ]] && { generate_remna_templates; remna_host_values > "$OUT_DIR/remnawave-host-${METHOD}.txt"; }
  fi
fi

if [[ "$PANEL_KIND" == remna ]]; then
  echo
  if [[ "$REMNA_ROLE" == panel ]]; then
    ok "Центральная Remnawave-панель установлена. На сервере панели XHTTP-нода не нужна."
    echo "Открой: https://${PANEL_DOMAIN}/ и создай первого администратора."
    echo "Дальше рабочий порядок:"
    echo "  1) В панели создай Node для европейского VPS, запомни Node Port и скопируй SECRET_KEY."
    echo "  2) На европейском VPS: этот же install.sh → Remnawave → Только нода → выбери CDN."
    echo "  3) После запуска ноды вернись на этот сервер и выполни: $INSTALL_PATH --manage-remna"
    echo "     Менеджер выберет эту ноду, спросит CDN/домены и попробует сам создать Profile, Active inbound, Squad и Host через API."
  else
    if [[ "$METHOD" == none ]]; then
      ok "Remnawave Node установлена БЕЗ CDN-метода. Это нормальный режим для relay/exit каскада."
      echo "На сервере центральной панели запусти: /root/panel-script-v1.sh --cascade"
      echo "Там выбери эту ноду как RELAY или EXIT. CDN Profile/Host сейчас создавать не нужно."
      [[ "${REMNA_EXISTING_PANEL_SIDE_BY_SIDE:-no}" == yes ]] && echo "Панель на этом же VPS не переустанавливалась; её nginx/ACME не переписывались."
    else
      warn "Remnawave: нода установлена. Теперь метод нужно привязать в центральной панели."
      echo "На СЕРВЕРЕ ПАНЕЛИ запусти: /root/panel-script-v1.sh --manage-remna"
      echo "Менеджер выберет эту ноду и попробует сам создать Profile, включить inbound, добавить его в Squad и создать Host."
      echo "Если API установленной версии отличается, он ничего не удалит и оставит готовые файлы для ручного ввода."
      echo
      echo "Готовые файлы на этой ноде:"
      echo "  $OUT_DIR/remnawave-profile-${METHOD}.json"
      echo "  $OUT_DIR/remnawave-host-extra-${METHOD}.json"
      echo "  $OUT_DIR/remnawave-host-${METHOD}.txt"
      echo
      echo "В панели сделай по порядку: Config profile → вставить profile JSON → назначить профиль ноде → Active inbounds → squad → user → host."
      echo "В host поле xhttpExtraParams вставить файл host-extra БЕЗ изменений."
      read -r -p "Если уже сделал — Enter для проверок; s = пропустить до следующего запуска: " p; [[ "${p,,}" == s ]] || true
    fi
  fi
fi

if [[ "$METHOD" == turboflare ]]; then
  echo
  echo "=== Контроль TurboFlare (исправление, которое реально решило текущую установку) ==="
  echo "В TurboFlare → Сайты → $( [[ -n "$CDN_DOMAIN" ]] && echo "$CDN_DOMAIN" || echo '<домен>' ) → Редактирование:"
  echo "  Адрес = ${PUBLIC_IP}:443"
  echo "  HTTPS к источнику = ВКЛ"
  echo "  Устаревший кэш при недоступности source = ВЫКЛ"
  echo "Сохрани. Сам CDN-домен после NS должен указывать на edge TurboFlare, НЕ на ${PUBLIC_IP}."
  read -r -p "Нажми Enter после проверки этого поля (s = пропустить): " _tf
fi

origin_code="skip"
if [[ "$METHOD" != none && ( "$PANEL_KIND" == 3xui || "$REMNA_ROLE" == node || "$REMNA_ROLE" == both ) ]]; then
  if [[ "$METHOD" == vk || "$METHOD" == timeweb ]]; then
    origin_code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "http://${PUBLIC_IP}${SERVER_PATH}" -H "Host: ${ORIGIN_DOMAIN:-$PUBLIC_IP}" 2>/dev/null || true)
  else
    origin_code=$(curl -sk --max-time 15 --resolve "check-origin.invalid:443:${PUBLIC_IP}" -H "Host: ${ORIGIN_DOMAIN:-$PUBLIC_IP}" "https://check-origin.invalid${SERVER_PATH}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  fi
fi
cdn_code="skip"
if [[ -n "${CDN_DOMAIN:-}" ]]; then cdn_code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "https://${CDN_DOMAIN}${CLIENT_PATH}" 2>/dev/null || true); fi

XRAY_VERSION="n/a"
if [[ "$PANEL_KIND" == 3xui ]]; then
  xb=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 | head -1 || true); [[ -n "$xb" ]] && XRAY_VERSION=$($xb version 2>/dev/null | head -1 || true)
elif [[ "$REMNA_ROLE" == node || "$REMNA_ROLE" == both ]]; then XRAY_VERSION=$(docker exec remnanode /usr/local/bin/xray version 2>/dev/null | head -1 || true); fi

{
  echo "CDN/XHTTP installer $INSTALLER_VERSION"
  echo "Panel: $PANEL_KIND"
  [[ "$PANEL_KIND" == remna ]] && echo "Remnawave role/version: $REMNA_ROLE / $REMNA_VERSION"
  [[ "$PANEL_KIND" == 3xui ]] && echo "3x-ui version: $XUI_VERSION"
  echo "Method: $(method_title "$METHOD")"
  echo "Public IP: $PUBLIC_IP"
  if [[ "$METHOD" != none ]]; then
    echo "Xray port/path: $XRAY_PORT $SERVER_PATH"
    echo "Client path: $CLIENT_PATH"
    echo "CDN domain: ${CDN_DOMAIN:-not-set-yet}"
    echo "Origin domain: ${ORIGIN_DOMAIN:-IP-source}"
    echo "Origin check: HTTP $origin_code (400 = nginx reached Xray)"
    echo "CDN check: HTTP $cdn_code (400 = CDN chain reached Xray)"
    echo "Xray: $XRAY_VERSION"
  fi
  if [[ "$PANEL_KIND" == 3xui ]]; then
    if [[ "${XUI_EXISTING:-no}" == yes ]]; then
      echo "3x-ui: existing installation detected; credentials were NOT changed by installer"
    else
      echo "3x-ui login: $XUI_USER"
      echo "3x-ui password: $XUI_PASS"
      echo "3x-ui local port/path: $XUI_PANEL_PORT /$XUI_PATH/"
      [[ -n "$PANEL_DOMAIN" ]] && echo "Panel URL: https://$PANEL_DOMAIN/$XUI_PATH/"
    fi
  elif [[ "$REMNA_ROLE" == panel || "$REMNA_ROLE" == both ]]; then
    echo "Remnawave URL: https://$PANEL_DOMAIN/"
    echo "Remnawave admin: created manually in web UI; installer does NOT store or know the actual password"
  fi
  [[ "$CASCADE" == yes ]] && echo "Cascade: requested; after base CDN check run: $INSTALL_PATH --cascade"
} > "$RESULT_FILE"
chmod 600 "$RESULT_FILE"
mark complete
if [[ "${REMNA_EXISTING_PANEL_SIDE_BY_SIDE:-no}" == yes && "$REMNA_ROLE" == node && "$METHOD" == none ]]; then
  REMNA_ROLE=both
  save_state
fi

cat > "$OUT_DIR/cascade-next-steps.txt" <<EOF
Каскад можно включить при первой установке или позже отдельной командой:
  $INSTALL_PATH --cascade

Remnawave: мастер выбирает relay и одну либо несколько exit-нод. На каждой exit готовится BRIDGE_IN :8888 и отдельный bridge-user.
Для нескольких exit relay profile создаёт VLESS_EXIT_* + routing.balancers/EXIT_POOL (roundRobin или random). Существующие active inbound на exit сохраняются.
Перед заменой активного profile relay всегда требуется отдельное подтверждение.
Provider-side origin/DNS и reverse proxy relay выводятся отдельной ручной инструкцией (Caddy на отдельном relay; существующий nginx при panel+relay на одном VPS).

3x-ui: пока создаётся безопасный чек-лист; финальный catch-all только по network=tcp,udp, не по inboundTag.
EOF
chmod 600 "$OUT_DIR/cascade-next-steps.txt"

echo
ok "Базовая установка/подготовка завершена."
if [[ "$METHOD" != none ]]; then
  echo "Origin XHTTP: HTTP $origin_code (ожидается 400 после активного inbound)."
  echo "CDN XHTTP:    HTTP $cdn_code (ожидается 400 после активного CDN-ресурса)."
fi
echo "Результат:    $RESULT_FILE"
echo "Шаблоны:      $OUT_DIR"
echo "Лог:           $LOG_FILE"
if [[ "${CASCADE:-no}" == yes ]]; then
  echo
  ui_title "КАСКАД ВЫБРАН"
  if [[ "$METHOD" == none ]]; then
    check_do "Служебная нода готова. На сервере центральной панели запусти: $INSTALL_PATH --cascade"
    manual_do "В мастере выбери эту ноду как RELAY или EXIT. CDN/origin на этой базовой установке не нужен."
  elif [[ "$origin_code" == 400 && "$cdn_code" == 400 ]]; then
    check_do "Базовый CDN уже отвечает 400/400. На сервере центральной панели можно переходить к: $INSTALL_PATH --cascade"
  else
    manual_do "Сначала доведи базовый CDN до origin=400 и CDN=400. Затем на сервере центральной панели: $INSTALL_PATH --cascade"
  fi
  manual_do "Каскад требует RU relay + минимум одну foreign exit-ноду. Можно выбрать пул exit-нод."
fi
echo "Повторный запуск продолжит с сохранёнными ответами."
