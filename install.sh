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

INSTALLER_VERSION="1.0.2"
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

C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'
info(){ echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok(){ echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
die(){ echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; exit 1; }
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
random_password(){ openssl rand -base64 24 | tr -d '\n' | tr '/+' 'Aa'; }
random_path(){ openssl rand -hex 8; }

save_state(){
  local t="$STATE_FILE.tmp"
  umask 077
  {
    printf 'STATE_SCHEMA=%q\n' "$STATE_SCHEMA_CURRENT"
    for k in PANEL_KIND REMNA_ROLE METHOD REMNA_VERSION XUI_VERSION UPGRADE_XUI_XRAY XUI_EXISTING PANEL_DOMAIN ORIGIN_DOMAIN CDN_DOMAIN ENABLE_UFW ENABLE_BBR CASCADE LE_EMAIL PANEL_IP REMNA_SECRET_KEY XUI_USER XUI_PASS XUI_PANEL_PORT XUI_PATH REMNA_ADMIN_USER REMNA_ADMIN_PASS; do
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
    timeweb) echo "Timeweb CDN" ;; selectel) echo "Selectel CDN" ;; turboflare) echo "TurboFlare" ;; *) echo "$1" ;;
  esac
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

show_config(){
  echo
  echo "================ Сохранённая конфигурация ================"
  echo "Панель          : $PANEL_KIND"
  [[ "$PANEL_KIND" == remna ]] && echo "Роль Remnawave  : ${REMNA_ROLE:-} / версия ${REMNA_VERSION:-}"
  [[ "$PANEL_KIND" == 3xui ]] && echo "Версия 3x-ui    : ${XUI_VERSION:-}"
  echo "Метод           : $(method_title "${METHOD:-none}")"
  if [[ "${METHOD:-none}" != none ]]; then
    echo "CDN-домен       : ${CDN_DOMAIN:-будет введён позже}"
    echo "Origin-домен    : ${ORIGIN_DOMAIN:-не используется / IP}"
  fi
  echo "Домен панели    : ${PANEL_DOMAIN:-нет}"
  echo "Каскад          : ${CASCADE:-no}"
  echo "Firewall / BBR  : ${ENABLE_UFW:-yes} / ${ENABLE_BBR:-yes}"
  echo "==========================================================="
}

choose_panel(){
  if [[ "$PRESET" == 3xui:* ]]; then PANEL_KIND=3xui; return; fi
  if [[ "$PRESET" == remna:* ]]; then PANEL_KIND=remna; return; fi
  echo
  echo "Выбери панель:"
  echo "  1 — Remnawave (все 6 методов; лучше для панели + множества нод)"
  echo "  2 — 3x-ui (только VK / Yandex / TurboFlare; совместимый режим v3.3.1)"
  while true; do read -r -p "Выбор [1]: " a; a="${a:-1}"; case "$a" in 1) PANEL_KIND=remna; break ;; 2) PANEL_KIND=3xui; break ;; esac; done
}
choose_remna_role(){
  echo
  echo "Что установить на ЭТОМ сервере?"
  echo "  1 — панель Remnawave"
  echo "  2 — только ноду Remnawave"
  echo "  3 — панель + ноду на одном сервере"
  while true; do read -r -p "Выбор [3]: " a; a="${a:-3}"; case "$a" in 1) REMNA_ROLE=panel; break ;; 2) REMNA_ROLE=node; break ;; 3) REMNA_ROLE=both; break ;; esac; done
}
choose_method(){
  if [[ -n "$PRESET" ]]; then
    METHOD="${PRESET#*:}"
    return
  fi
  echo
  if [[ "$PANEL_KIND" == 3xui ]]; then
    echo "Метод CDN (для 3x-ui доступны только проверенные в файлах):"
    echo "  1 — VK Cloud"
    echo "  2 — Yandex Cloud"
    echo "  3 — TurboFlare"
    while true; do read -r -p "Выбор [3]: " a; a="${a:-3}"; case "$a" in 1) METHOD=vk; break ;; 2) METHOD=yandex; break ;; 3) METHOD=turboflare; break ;; esac; done
  else
    echo "Метод CDN:"
    echo "  1 — VK Cloud"
    echo "  2 — Yandex Cloud"
    echo "  3 — Beeline / CDNvideo"
    echo "  4 — Timeweb"
    echo "  5 — Selectel"
    echo "  6 — TurboFlare"
    while true; do read -r -p "Выбор [6]: " a; a="${a:-6}"; case "$a" in 1) METHOD=vk; break ;; 2) METHOD=yandex; break ;; 3) METHOD=beeline; break ;; 4) METHOD=timeweb; break ;; 5) METHOD=selectel; break ;; 6) METHOD=turboflare; break ;; esac; done
  fi
}

collect_config(){
  echo
  echo "=== CDN/XHTTP Universal Installer $INSTALLER_VERSION ==="
  echo "Примеры доменов вымышленные; реальные домены в код не зашиваются."
  choose_panel
  if [[ "$PANEL_KIND" == remna ]]; then
    choose_remna_role
    echo
    echo "Версия Remnawave:"
    echo "  1 — $REMNA_MANUAL_VERSION (по присланным мануалам, рекомендуется для первого теста)"
    echo "  2 — $REMNA_NEWER_VERSION (новее; конфиги методов ещё надо перепроверить на практике)"
    read -r -p "Выбор [1]: " rv; rv="${rv:-1}"; [[ "$rv" == 2 ]] && REMNA_VERSION="$REMNA_NEWER_VERSION" || REMNA_VERSION="$REMNA_MANUAL_VERSION"
    XUI_VERSION=""
  else
    REMNA_ROLE=""; REMNA_VERSION=""
    XUI_VERSION="$XUI_COMPAT_VERSION"
    echo
    warn "3x-ui фиксируется на $XUI_VERSION: в этих мануалах ссылка строится через legacy External Proxy."
    warn "Новые версии 3x-ui используют другой механизм Hosts; их не включаю автоматически до отдельной проверки."
    ask_yes_no UPGRADE_XUI_XRAY "После установки заменить bundled Xray на $XRAY_MANUAL_VERSION? (мануалы рекомендуют; для уже рабочего TurboFlare 26.6.1 менять не обязательно)" "no"
  fi

  # Для отдельной центральной Remnawave-панели CDN не нужен.
  if [[ "$PANEL_KIND" == remna && "$REMNA_ROLE" == panel ]]; then
    METHOD=none
  else
    choose_method
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
    PANEL_DOMAIN=""
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

  read -r -p "Email для Let's Encrypt (Enter = без email)${LE_EMAIL:+ [$LE_EMAIL]}: " _mail
  LE_EMAIL="${_mail:-${LE_EMAIL:-}}"
  ask_yes_no ENABLE_UFW "Настроить UFW: входящие SSH/80/443, исходящие разрешены? (рекомендуется)" "yes"
  ask_yes_no ENABLE_BBR "Включить BBR + базовый TCP-тюнинг? (рекомендуется)" "yes"
  if [[ "$METHOD" == none ]]; then
    CASCADE=no
  else
    ask_yes_no CASCADE "Нужен каскад через второй сервер? (пока сначала ставится базовый CDN, затем будет создан чек-лист)" "no"
  fi

  if [[ "$PANEL_KIND" == remna && "$REMNA_ROLE" == node ]]; then
    read -r -p "IP сервера панели Remnawave: " PANEL_IP
    while ! valid_ipv4 "$PANEL_IP"; do read -r -p "Нужен IPv4 панели: " PANEL_IP; done
    read -r -p "SECRET_KEY ноды из панели Remnawave: " REMNA_SECRET_KEY
    [[ -n "$REMNA_SECRET_KEY" ]] || die "Для node-only нужен SECRET_KEY."
  fi
  save_state
  show_config
  read -r -p "Нажми Enter, чтобы начать..." _
}

case "${1:-}" in
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
  --help|-h)
    cat <<EOF
${PROJECT_NAME} ${INSTALLER_VERSION}

Запуск: $INSTALL_PATH
Статус: $INSTALL_PATH --status
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
  cp -a /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
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

install_docker(){
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && return 0
  curl -fsSL https://get.docker.com | sh
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
}

install_remna_panel(){
  marked remna_panel && return 0
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
  "$dest" version | head -1
}

install_remna_node(){
  marked remna_node && return 0
  install_docker
  mkdir -p /opt/remnanode
  download_xray /opt/remnanode/xray-custom "$XRAY_MANUAL_VERSION"

  if [[ "$REMNA_ROLE" == both ]]; then
    echo
    warn "Нужен SECRET_KEY ноды из только что установленной панели."
    echo "Открой https://${PANEL_DOMAIN}/, зарегистрируй первого администратора."
    echo "Рекомендуемые доступы (сохраняются только root на сервере):"
    echo "  Логин:  $REMNA_ADMIN_USER"
    echo "  Пароль: $REMNA_ADMIN_PASS"
    echo "Потом: Nodes → Create node → Address=$PUBLIC_IP → Port=2222 → скопируй SECRET_KEY."
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
NODE_PORT=2222
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
iptables -C INPUT -p tcp --dport 2222 -j "\$CHAIN" 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 2222 -j "\$CHAIN"
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
  iid=$(echo "$list" | jq -r --argjson p "$XRAY_PORT" '.obj[]? | select(.port==$p and .protocol=="vless") | .id' | head -1)
  if [[ "$iid" =~ ^[0-9]+$ ]]; then
    resp=$(curl -sS --max-time 20 -b "$cookie" -H 'Content-Type: application/json' -X POST --data-binary "$payload" "$base/panel/api/inbounds/update/$iid" 2>/dev/null || true)
  else
    resp=$(curl -sS --max-time 20 -b "$cookie" -H 'Content-Type: application/json' -X POST --data-binary "$payload" "$base/panel/api/inbounds/add" 2>/dev/null || true)
  fi
  rm -f "$cookie"
  if echo "$resp" | jq -e '.success==true' >/dev/null 2>&1; then ok "3x-ui inbound создан/обновлён автоматически."; else warn "API не принял inbound: ${resp:-нет ответа}"; warn "Используй файл $OUT_DIR/3xui-inbound.json вручную."; fi
  mark xui_inbound
}

remna_inbound_json(){
  case "$METHOD" in
    vk) cat <<'JSON'
{"tag":"cdn-stream","port":10085,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","mode":"packet-up","path":"/content/media/stream/","noSSEHeader":false,"xPaddingKey":"_token","xPaddingBytes":"16-64","xPaddingHeader":"X-Signature","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxBufferedPosts":50,"scMaxEachPostBytes":"500000-1000000","scMinPostsIntervalMs":"50-150","scStreamUpServerSecs":"60-180","serverMaxHeaderBytes":0,"xmux":{"cMaxReuseTimes":"0","maxConnections":"1","hKeepAlivePeriod":0,"hMaxRequestTimes":"300-600","hMaxReusableSecs":"900-1800"}}}}
JSON
      ;;
    yandex) cat <<'JSON'
{"tag":"yasha","port":4443,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"routeOnly":false,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/uploadfiles/","xPaddingKey":"_dc","xPaddingHeader":"X-Cache","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader","uplinkHTTPMethod":"get"}}}
JSON
      ;;
    beeline) cat <<'JSON'
{"tag":"cdn-beeline","port":10086,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/static/getFile/video/segment.ts","extra":{"xmux":{"maxConcurrency":"1"},"seqKey":"chunk_id","sessionKey":"auth","noSSEHeader":true,"noGRPCHeader":true,"seqPlacement":"query","sessionIDKey":"auth","sessionIDLength":"16-32","sessionPlacement":"query","sessionIDPlacement":"query","xPaddingBytes":"50-150","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"header","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxBufferedPosts":100,"scMaxEachPostBytes":3000000,"scMinPostsIntervalMs":"5-10","serverMaxHeaderBytes":32768}}}}
JSON
      ;;
    timeweb) cat <<'JSON'
{"tag":"cdn-timeweb","port":10087,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/content/media/","extra":{"sessionIDPlacement":"query","sessionIDKey":"sid","seqPlacement":"query","seqKey":"offset","noSSEHeader":false,"uplinkHTTPMethod":"GET","uplinkDataPlacement":"header","uplinkDataKey":"X-Playback-Token","xPaddingKey":"q","xPaddingBytes":"48-256","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","scMaxEachPostBytes":"4096-16384","scMinPostsIntervalMs":"1-8","serverMaxHeaderBytes":32768}}}}
JSON
      ;;
    selectel) cat <<'JSON'
{"tag":"cdn-selectel","port":10088,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/api/uploadFile/","extra":{"seqKey":"page","seqPlacement":"query","noSSEHeader":false,"sessionIDKey":"X-Request-Id","sessionIDPlacement":"header","uplinkHTTPMethod":"POST","uplinkDataKey":"X-Payload","uplinkDataPlacement":"body","xPaddingKey":"q","xPaddingBytes":"80-240","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","scMaxEachPostBytes":"65536-262144","scMinPostsIntervalMs":"20-50","serverMaxHeaderBytes":32768}}}}
JSON
      ;;
    turboflare) cat <<'JSON'
{"tag":"cdn-turboflare","port":10089,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"mode":"packet-up","path":"/static/getFile/video/segment.ts","extra":{"xmux":{"maxConcurrency":"1"},"seqKey":"chunk_id","sessionKey":"auth","noSSEHeader":true,"noGRPCHeader":true,"seqPlacement":"query","sessionIDKey":"auth","sessionPlacement":"query","sessionIDPlacement":"query","xPaddingBytes":"50-150","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"header","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxBufferedPosts":100,"scMaxEachPostBytes":3000000,"scMinPostsIntervalMs":"5-10","serverMaxHeaderBytes":32768}}}}
JSON
      ;;
  esac
}

remna_host_extra_json(){
  case "$METHOD" in
    vk) cat <<'JSON'
{"xmux":{"cMaxReuseTimes":"0","maxConnections":"1","hKeepAlivePeriod":0,"hMaxRequestTimes":"300-600","hMaxReusableSecs":"900-1800"},"noSSEHeader":false,"xPaddingKey":"_token","xPaddingBytes":"16-64","xPaddingHeader":"X-Signature","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"query","uplinkHTTPMethod":"GET","uplinkDataPlacement":"body","scMaxEachPostBytes":"500000-1000000","scMinPostsIntervalMs":"50-150","scStreamUpServerSecs":"60-180"}
JSON
      ;;
    yandex) cat <<'JSON'
{"mode":"packet-up","xPaddingKey":"_dc","xPaddingHeader":"X-Cache","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader","uplinkHTTPMethod":"get"}
JSON
      ;;
    beeline) jq '.streamSettings.xhttpSettings.extra' <<<"$(remna_inbound_json)" ;;
    timeweb) jq '.streamSettings.xhttpSettings.extra' <<<"$(remna_inbound_json)" ;;
    selectel) jq '.streamSettings.xhttpSettings.extra' <<<"$(remna_inbound_json)" ;;
    turboflare) jq '.streamSettings.xhttpSettings.extra' <<<"$(remna_inbound_json)" ;;
  esac
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
  cat "$f"
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
    generate_remna_templates
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
    ok "Центральная Remnawave-панель установлена. CDN и XHTTP для panel-only режима не настраиваются."
    echo "Открой: https://${PANEL_DOMAIN}/"
    echo "Создай первого администратора, затем для каждой новой ноды используй этот же install.sh → Remnawave → Только нода."
  else
    warn "Remnawave: нода установлена, но профиль/host нужно добавить в центральной панели."
    echo "Готовые файлы:"
    echo "  $OUT_DIR/remnawave-profile-${METHOD}.json"
    echo "  $OUT_DIR/remnawave-host-extra-${METHOD}.json"
    echo "  $OUT_DIR/remnawave-host-${METHOD}.txt"
    echo
    echo "В панели сделай по порядку: Config profile → вставить profile JSON → назначить профиль ноде → Active inbounds → squad → user → host."
    echo "В host поле xhttpExtraParams вставить файл host-extra БЕЗ изменений."
    read -r -p "Если уже сделал — Enter для проверок; s = пропустить до следующего запуска: " p; [[ "${p,,}" == s ]] || true
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
if [[ "$PANEL_KIND" == 3xui || "$REMNA_ROLE" == node || "$REMNA_ROLE" == both ]]; then
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
    echo "Suggested first admin login: $REMNA_ADMIN_USER"
    echo "Suggested first admin password: $REMNA_ADMIN_PASS"
  fi
  [[ "$CASCADE" == yes ]] && echo "Cascade: requested; base CDN configured first. Do not alter routing until both origin/CDN checks are 400."
} > "$RESULT_FILE"
chmod 600 "$RESULT_FILE"
mark complete

cat > "$OUT_DIR/cascade-next-steps.txt" <<'EOF'
Каскад включается только после базовой проверки CDN (origin=400 и CDN=400).
В этой версии установщика каскад намеренно не меняет routing автоматически: один неверный tag/UUID отрезает рабочую ноду.
Для 3x-ui правило каскада не привязывать к inboundTag: панель может переименовать inbound; использовать catch-all по network.
Для Remnawave каскад добавляется в config profile после проверки relay->exit отдельно.
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
echo "Повторный запуск продолжит с сохранёнными ответами."
