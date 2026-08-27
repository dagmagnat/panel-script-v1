#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:-install.sh}"
[[ -f "$TARGET" ]] || { echo "[ERR] Не найден файл: $TARGET" >&2; exit 1; }

BACKUP="${TARGET}.bak-before-v1.2.5-$(date +%Y%m%d-%H%M%S)"
cp -a "$TARGET" "$BACKUP"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

m = re.search(r'^INSTALLER_VERSION="([^"]+)"$', s, re.M)
if not m:
    raise SystemExit('[ERR] INSTALLER_VERSION не найден')
version = m.group(1)
if version == '1.2.5':
    print('[OK] install.sh уже версии 1.2.5; повторный патч не требуется')
    raise SystemExit(0)
if version not in {'1.2.3', '1.2.4'}:
    raise SystemExit(f'[ERR] Hotfix рассчитан на v1.2.3/v1.2.4 (найдено {version}).')
s = re.sub(r'^INSTALLER_VERSION="[^"]+"$', 'INSTALLER_VERSION="1.2.5"', s, count=1, flags=re.M)

# ---------------------------------------------------------------------------
# v1.2.4 bridge-user fix, made idempotent for both 1.2.3 and 1.2.4 inputs.
# ---------------------------------------------------------------------------
start_bridge = s.find('rm_api_save_redacted_response(){')
if start_bridge < 0:
    start_bridge = s.find('rm_api_ensure_bridge_user(){')
end_bridge = s.find('\nrun_remna_cascade_manager(){', start_bridge)
if start_bridge < 0 or end_bridge < 0:
    raise SystemExit('[ERR] Не найден блок bridge-user перед run_remna_cascade_manager')

bridge_block = r'''rm_api_save_redacted_response(){
  local out="$1" data="$2"
  umask 077
  if jq -e . >/dev/null 2>&1 <<<"$data"; then
    jq '
      walk(
        if type=="object" then
          with_entries(
            if (.key | ascii_downcase | test("password|token|secret|subscriptionurl|vlessuuid"))
            then .value="<redacted>"
            else .
            end
          )
        else . end
      )
    ' <<<"$data" > "$out" 2>/dev/null || printf '%s\n' '[response redaction failed]' > "$out"
  else
    printf '%s\n' "$data" > "$out"
  fi
  chmod 600 "$out"
  umask 022
}
rm_api_ensure_bridge_user(){
  local token="$1" username="$2" desired_uuid="$3" squad_uuid="$4"
  local r user user_uuid vless old arr body resp expire created_vless

  r=$(rm_api GET "/api/users/by-username/${username}" "$token" 2>/dev/null || true)
  user=$(jq -c '.response.user // .response // empty' <<<"$r" 2>/dev/null || true)
  vless=$(jq -r '.vlessUuid // .vless_uuid // empty' <<<"$user" 2>/dev/null || true)

  if [[ -n "$vless" ]]; then
    old=$(jq -c \
      '[.activeInternalSquads[]? |
        if type=="string" then . else .uuid end |
        select(.!=null and .!="")]' \
      <<<"$user" 2>/dev/null || echo '[]')

    if jq -e --arg s "$squad_uuid" 'index($s) != null' >/dev/null 2>&1 <<<"$old"; then
      printf '%s' "$vless"
      return 0
    fi

    user_uuid=$(jq -r '.uuid // empty' <<<"$user" 2>/dev/null || true)
    if [[ -n "$user_uuid" ]]; then
      arr=$(jq -nc --argjson o "$old" --arg s "$squad_uuid" '$o + [$s] | unique')
      body=$(jq -nc --arg u "$user_uuid" --argjson a "$arr" '{uuid:$u,activeInternalSquads:$a}')
      resp=$(rm_api PATCH /api/users "$token" "$body" 2>/dev/null || true)
      if jq -e --arg s "$squad_uuid" '
           (.response // .) as $u |
           [($u.activeInternalSquads // [])[]? |
             if type=="string" then . else .uuid end] |
           index($s) != null
         ' >/dev/null 2>&1 <<<"$resp"; then
        printf '%s' "$vless"
        return 0
      fi
      rm_api_save_redacted_response "$RM_MANAGER_DIR/last-api-error-cascade-user.json" "$resp"
      return 2
    fi

    rm_api_save_redacted_response "$RM_MANAGER_DIR/last-api-error-cascade-user.json" "$r"
    return 2
  fi

  expire=$(date -u -d '+10 years' '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  body=$(jq -nc \
    --arg n "$username" \
    --arg e "$expire" \
    --arg v "$desired_uuid" \
    --arg s "$squad_uuid" \
    '{username:$n,
      expireAt:$e,
      trafficLimitBytes:0,
      trafficLimitStrategy:"NO_RESET",
      vlessUuid:$v,
      activeInternalSquads:[$s]}')

  resp=$(rm_api POST /api/users "$token" "$body" 2>/dev/null || true)
  created_vless=$(jq -r '.response.vlessUuid // .vlessUuid // empty' <<<"$resp" 2>/dev/null || true)

  if [[ -n "$created_vless" ]]; then
    if jq -e --arg s "$squad_uuid" '
         [((.response.activeInternalSquads // .activeInternalSquads // [])[]?) |
           if type=="string" then . else .uuid end] |
         index($s) != null
       ' >/dev/null 2>&1 <<<"$resp"; then
      printf '%s' "$created_vless"
      return 0
    fi
    rm_api_save_redacted_response "$RM_MANAGER_DIR/last-api-error-cascade-user.json" "$resp"
    return 2
  fi

  rm_api_save_redacted_response "$RM_MANAGER_DIR/last-api-error-cascade-user.json" "$resp"
  return 1
}'''

s = s[:start_bridge] + bridge_block + s[end_bridge:]

# ---------------------------------------------------------------------------
# Domain helpers. Parent-zone layout remains blocked by default, but v1.2.5
# allows an explicit opt-in for providers such as TurboFlare where the whole
# parent zone is already authoritative on the CDN DNS and panel/origin A records
# are deliberately maintained there.
# ---------------------------------------------------------------------------
collect = s.find('rm_manager_collect_domains(){')
if collect < 0:
    raise SystemExit('[ERR] Не найден rm_manager_collect_domains')
helper_start = s.rfind('rm_domain_is_same_or_child(){', 0, collect)
if helper_start >= 0:
    s = s[:helper_start] + s[collect:]
    collect = helper_start

helper = r'''rm_domain_is_same_or_child(){
  local child="${1,,}" parent="${2,,}"
  [[ -n "$child" && -n "$parent" ]] || return 1
  [[ "$child" == "$parent" || "$child" == *."$parent" ]]
}
rm_turboflare_domain_conflicts(){
  local cdn="${CDN_DOMAIN:-}" d
  [[ -n "$cdn" ]] || return 1
  for d in "${PANEL_DOMAIN:-}" "${ORIGIN_DOMAIN:-}"; do
    [[ -n "$d" ]] || continue
    if rm_domain_is_same_or_child "$d" "$cdn"; then
      return 0
    fi
  done
  return 1
}
rm_turboflare_parent_zone_allowed(){
  [[ "${PSV1_ALLOW_PARENT_CDN:-0}" == "1" ]]
}
'''
s = s[:collect] + helper + s[collect:]

# ---------------------------------------------------------------------------
# v1.2.5: local nginx bridge for TurboFlare IP-origin mode.
# TurboFlare can be configured with origin IP only. In that mode it may reach
# the relay with Host=aer01.ru and the local Remnawave panel default_server used
# to swallow the XHTTP path and return panel JSON 404. This helper injects a
# path-only exception into the local panel HTTPS vhost:
#   /static/getFile/video/segment.ts -> 127.0.0.1:7443
# It does not replace panel /, does not touch VLESS_EXIT, and rolls back on
# nginx -t failure.
# ---------------------------------------------------------------------------
nginx_helper = r'''rm_ensure_turboflare_cascade_nginx_bridge(){
  local conf="/etc/nginx/sites-available/remnawave-panel.conf"
  local enabled="/etc/nginx/sites-enabled/remnawave-panel.conf"
  local backup="${conf}.before-psv1-cascade-$(date +%Y%m%d-%H%M%S)"

  command -v nginx >/dev/null 2>&1 || {
    warn "TurboFlare cascade frontend: nginx не установлен локально; пропускаю автопатч."
    return 0
  }
  [[ -f "$conf" && -e "$enabled" ]] || {
    warn "TurboFlare cascade frontend: локальный remnawave-panel.conf не найден/не enabled; пропускаю автопатч."
    return 0
  }

  if nginx -T 2>/dev/null | grep -q 'PSV1-CASCADE-TURBOFLARE BEGIN'; then
    ok "TurboFlare cascade frontend уже активен: /static/getFile/video/segment.ts -> 127.0.0.1:7443"
    return 0
  fi

  cp -a "$conf" "$backup"
  if ! python3 - "$conf" "${PANEL_DOMAIN:-}" <<'PYNG'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
panel_domain = sys.argv[2]
s = path.read_text()

marker = 'PSV1-CASCADE-TURBOFLARE BEGIN'
if marker in s:
    raise SystemExit(0)

# Find complete top-level server blocks by brace depth.
blocks = []
pos = 0
while True:
    m = re.search(r'(?m)^\s*server\s*\{', s[pos:])
    if not m:
        break
    start = pos + m.start()
    brace = s.find('{', start)
    depth = 0
    i = brace
    in_sq = in_dq = False
    esc = False
    while i < len(s):
        ch = s[i]
        if esc:
            esc = False
        elif ch == '\\':
            esc = True
        elif ch == "'" and not in_dq:
            in_sq = not in_sq
        elif ch == '"' and not in_sq:
            in_dq = not in_dq
        elif not in_sq and not in_dq:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    blocks.append((start, end, s[start:end]))
                    pos = end
                    break
        i += 1
    else:
        raise SystemExit('[ERR] nginx parser: незакрытый server block')

chosen = None
for start, end, block in blocks:
    if not re.search(r'(?m)^\s*listen\s+.*443.*;', block):
        continue
    if panel_domain and re.search(r'(?m)^\s*server_name\s+[^;]*\b' + re.escape(panel_domain) + r'\b[^;]*;', block):
        chosen = (start, end, block)
        break
    if chosen is None and re.search(r'(?m)^\s*server_name\s+[^;]*\b_\b[^;]*;', block):
        chosen = (start, end, block)

if chosen is None:
    raise SystemExit('[ERR] Не найден HTTPS server block панели (listen 443)')

start, end, block = chosen
m = re.search(r'(?m)^(\s*)location\s+/\s*\{', block)
if not m:
    raise SystemExit('[ERR] В HTTPS server block панели не найден location / {')
indent = m.group(1)

location = f"""{indent}# PSV1-CASCADE-TURBOFLARE BEGIN
{indent}location ^~ /static/getFile/video/segment.ts {{
{indent}    rewrite ^/static/getFile/video/segment\\.ts$ /static/getFile/video/segment.ts/ break;
{indent}    proxy_pass http://127.0.0.1:7443;
{indent}    proxy_http_version 1.1;
{indent}    proxy_set_header Connection "";
{indent}    proxy_set_header Host $host;
{indent}    proxy_set_header X-Real-IP $remote_addr;
{indent}    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
{indent}    proxy_set_header X-Forwarded-Proto https;
{indent}    proxy_pass_request_headers on;
{indent}    proxy_buffering off;
{indent}    proxy_request_buffering off;
{indent}    proxy_cache off;
{indent}    proxy_max_temp_file_size 0;
{indent}    gzip off;
{indent}    client_max_body_size 0;
{indent}    proxy_connect_timeout 10s;
{indent}    proxy_read_timeout 1h;
{indent}    proxy_send_timeout 1h;
{indent}    send_timeout 1h;
{indent}    proxy_socket_keepalive on;
{indent}    add_header X-Accel-Buffering no always;
{indent}    add_header Cache-Control "no-store, no-cache" always;
{indent}    add_header CDN-Cache-Control "no-store" always;
{indent}    add_header Pragma "no-cache" always;
{indent}    add_header Expires "0" always;
{indent}    add_header Accept-Ranges none always;
{indent}}}
{indent}# PSV1-CASCADE-TURBOFLARE END\n\n"""

insert_at = start + m.start()
s = s[:insert_at] + location + s[insert_at:]
path.write_text(s)
PYNG
  then
    cp -a "$backup" "$conf"
    warn "Не удалось добавить TurboFlare cascade location; конфиг восстановлен: $backup"
    return 1
  fi

  if ! nginx -t; then
    cp -a "$backup" "$conf"
    nginx -t >/dev/null 2>&1 || true
    warn "nginx -t не прошёл; конфиг восстановлен: $backup"
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx
  else
    nginx -s reload
  fi

  if nginx -T 2>/dev/null | grep -q 'PSV1-CASCADE-TURBOFLARE BEGIN' && \
     nginx -T 2>/dev/null | grep -q 'proxy_pass http://127.0.0.1:7443'; then
    ok "TurboFlare cascade frontend включён: path -> 127.0.0.1:7443"
    auto_done "nginx: TurboFlare cascade path -> 127.0.0.1:7443"
  else
    warn "nginx reload выполнен, но автопроверка cascade location не подтвердилась. Backup: $backup"
    return 1
  fi

  if ss -ltn 2>/dev/null | grep -qE '127\.0\.0\.1:7443\b'; then
    ok "Cascade XHTTP уже слушает 127.0.0.1:7443"
  else
    warn "127.0.0.1:7443 пока не слушается. После синхронизации relay-профиля проверь Active Inbounds."
  fi
  return 0
}
'''

rr = s.find('run_remna_cascade_manager(){')
if rr < 0:
    raise SystemExit('[ERR] Не найден run_remna_cascade_manager')
if 'rm_ensure_turboflare_cascade_nginx_bridge(){' not in s:
    s = s[:rr] + nginx_helper + s[rr:]

# ---------------------------------------------------------------------------
# Replace the v1.2.4 hard stop with explicit opt-in support.
# ---------------------------------------------------------------------------
cs = s.find('run_remna_cascade_manager(){')
ce = s.find('\nrun_3xui_cascade_manager(){', cs)
if cs < 0 or ce < 0:
    raise SystemExit('[ERR] Не найден run_remna_cascade_manager block')
chunk = s[cs:ce]
needle = '  rm_manager_collect_domains "$method"\n'
if needle not in chunk:
    raise SystemExit('[ERR] Не найдена точка проверки TurboFlare domain')

# Remove an existing old/new guard immediately after domain collection.
after = chunk.find(needle) + len(needle)
if chunk.startswith('  if [[ "$method" == turboflare ]] && rm_turboflare_domain_conflicts; then\n', after):
    # Find the matching first top-level "  fi\n" for this simple guard.
    guard_end = chunk.find('  fi\n', after)
    if guard_end < 0:
        raise SystemExit('[ERR] Не удалось разобрать существующий TurboFlare domain guard')
    chunk = chunk[:after] + chunk[guard_end + len('  fi\n'):]

guard = r'''  if [[ "$method" == turboflare ]] && rm_turboflare_domain_conflicts; then
    if rm_turboflare_parent_zone_allowed; then
      warn "TurboFlare parent-zone override: CDN_DOMAIN='$CDN_DOMAIN' содержит PANEL_DOMAIN='$PANEL_DOMAIN' и/или ORIGIN_DOMAIN='${ORIGIN_DOMAIN:-}'."
      warn "Продолжаю только потому, что PSV1_ALLOW_PARENT_CDN=1. Убедись, что A-записи panel/origin реально существуют на авторитетных NS TurboFlare."
    else
      danger "TurboFlare NS-конфликт: '$CDN_DOMAIN' является родительской DNS-зоной для панели и/или origin."
      manual_do "Если это осознанная схема и DNS всей зоны уже обслуживает TurboFlare, перезапусти так: PSV1_ALLOW_PARENT_CDN=1 $INSTALL_PATH --cascade"
      manual_do "По умолчанию API каскада не меняю."
      return 0
    fi
  fi
'''
chunk = chunk.replace(needle, needle + guard, 1)
s = s[:cs] + chunk + s[ce:]

# ---------------------------------------------------------------------------
# Cascade manager fallback (v1.2.4 behavior).
# ---------------------------------------------------------------------------
rs = s.find('run_cascade_manager(){')
re_ = s.find('\n\nrun_remna_panel_manager(){', rs)
if rs < 0 or re_ < 0:
    raise SystemExit('[ERR] Не найден run_cascade_manager')
run_cascade = r'''run_cascade_manager(){
  local entered_url=""
  load_state || true

  if rm_panel_detected >/dev/null 2>&1; then
    run_remna_cascade_manager
    return 0
  fi

  if [[ "${PANEL_KIND:-}" == 3xui ]] || command -v x-ui >/dev/null 2>&1 || [[ -d /etc/x-ui ]]; then
    run_3xui_cascade_manager
    return 0
  fi

  warn "Remnawave API автоматически не найден. Это не означает, что панель не работает."
  read -r -p "URL центральной Remnawave (пример https://panel.example.com; Enter = отмена): " entered_url
  entered_url="${entered_url%/}"
  [[ -n "$entered_url" ]] || {
    manual_do "Запуск с URL без вопроса: RM_API_BASE=https://panel.example.com $INSTALL_PATH --cascade"
    return 0
  }

  if rm_try_api_base "$entered_url"; then
    ok "Remnawave API найден вручную: ${RM_API_BASE}"
    run_remna_cascade_manager
    return 0
  fi

  die "URL '$entered_url' не отвечает как Remnawave API. Ничего в панели не изменено."
}'''
s = s[:rs] + run_cascade + s[re_:]

# ---------------------------------------------------------------------------
# Terminal visibility + automatic local frontend fix at the end of cascade.
# ---------------------------------------------------------------------------
summary_anchor = '  [[ -n "$host_uuid" ]] && auto_done "Cascade Host: $CDN_DOMAIN"\n'
if summary_anchor in s:
    # Remove older v1.2.4 reminder if it immediately follows, then add the v1.2.5 block.
    old_reminder = '  manual_do "ВАЖНО: обычные пользователи НЕ добавляются в PSV1-CASCADE автоматически. Добавь нужных пользователей в этот Internal Squad, иначе Cascade Host не появится в их подписке."\n'
    idx = s.find(summary_anchor) + len(summary_anchor)
    if s.startswith(old_reminder, idx):
        s = s[:idx] + s[idx + len(old_reminder):]
    inject = summary_anchor + r'''  manual_do "ВАЖНО: обычные пользователи НЕ добавляются в PSV1-CASCADE автоматически. Добавь нужных пользователей в этот Internal Squad, иначе Cascade Host не появится в их подписке."
  if [[ "$method" == turboflare ]]; then
    rm_ensure_turboflare_cascade_nginx_bridge || manual_do "TurboFlare frontend не удалось применить автоматически. Запусти отдельный cascade-nginx-fix.sh из hotfix-pack."
  fi
'''
    s = s.replace(summary_anchor, inject, 1)
else:
    raise SystemExit('[ERR] Не найден summary anchor Cascade Host')

p.write_text(s)
print('[OK] install.sh обновлён до v1.2.5')
PY

chmod 700 "$TARGET"
if ! bash -n "$TARGET"; then
  cp -a "$BACKUP" "$TARGET"
  echo "[ERR] bash -n не прошёл. Восстановлен backup: $BACKUP" >&2
  exit 1
fi

echo "[OK] bash -n: syntax OK"
echo "[OK] Backup: $BACKUP"
VER_OUT=$("$TARGET" --version 2>/dev/null || true)
[[ -n "$VER_OUT" ]] || VER_OUT=$(grep -m1 '^INSTALLER_VERSION=' "$TARGET" || true)
echo "[OK] Version: $VER_OUT"
echo "[INFO] Для parent-zone TurboFlare (например aer01.ru + pnl.aer01.ru) запускай cascade так:"
echo "       PSV1_ALLOW_PARENT_CDN=1 $TARGET --cascade"
