#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_DOMAIN=""
CASCADE_PORT="7443"
CONF="/etc/nginx/sites-available/remnawave-panel.conf"

usage(){
  cat <<USAGE
Usage:
  $0 --panel-domain pnl.example.com [--cascade-port 7443] [--conf /path/to/panel.conf] [--apply]

Dry-run by default. The script patches only the HTTPS panel vhost path:
  /static/getFile/video/segment.ts -> 127.0.0.1:<cascade-port>

It creates a backup and rolls back if nginx -t fails.
USAGE
}

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-domain) PANEL_DOMAIN="${2:-}"; shift 2 ;;
    --cascade-port) CASCADE_PORT="${2:-}"; shift 2 ;;
    --conf) CONF="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[FAIL] Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "[FAIL] Run as root" >&2; exit 1; }
[[ -n "$PANEL_DOMAIN" ]] || { echo "[FAIL] --panel-domain is required" >&2; exit 2; }
[[ "$CASCADE_PORT" =~ ^[0-9]+$ ]] && (( 10#$CASCADE_PORT >= 1 && 10#$CASCADE_PORT <= 65535 )) || { echo "[FAIL] Bad --cascade-port" >&2; exit 2; }
command -v nginx >/dev/null 2>&1 || { echo "[FAIL] nginx not found" >&2; exit 1; }
[[ -f "$CONF" ]] || { echo "[FAIL] $CONF not found" >&2; exit 1; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cp -a "$CONF" "$TMP"

python3 - "$TMP" "$PANEL_DOMAIN" "$CASCADE_PORT" <<'PY'
from pathlib import Path
import re, sys
path=Path(sys.argv[1]); panel=sys.argv[2]; port=sys.argv[3]; s=path.read_text(encoding='utf-8')
if 'PSV1-CASCADE-TURBOFLARE BEGIN' in s:
    expected=f'proxy_pass http://127.0.0.1:{port};'
    if expected not in s:
        raise SystemExit(f'[FAIL] marker exists, but expected "{expected}" was not found')
    print('[OK] marker already present')
    raise SystemExit(0)
blocks=[]; pos=0
while True:
    m=re.search(r'(?m)^\s*server\s*\{', s[pos:])
    if not m: break
    start=pos+m.start(); brace=s.find('{', start); depth=0; i=brace; sq=dq=esc=False
    while i < len(s):
        ch=s[i]
        if esc: esc=False
        elif ch=='\\': esc=True
        elif ch=="'" and not dq: sq=not sq
        elif ch=='"' and not sq: dq=not dq
        elif not sq and not dq:
            if ch=='{': depth+=1
            elif ch=='}':
                depth-=1
                if depth==0:
                    end=i+1; blocks.append((start,end,s[start:end])); pos=end; break
        i+=1
    else: raise SystemExit('[FAIL] Unclosed nginx server block')
chosen=None
for st,en,b in blocks:
    if not re.search(r'(?m)^\s*listen\s+.*443.*;', b): continue
    if re.search(r'(?m)^\s*server_name\s+[^;]*\b'+re.escape(panel)+r'\b[^;]*;', b):
        chosen=(st,en,b); break
    if chosen is None and re.search(r'(?m)^\s*server_name\s+[^;]*\b_\b[^;]*;', b): chosen=(st,en,b)
if not chosen: raise SystemExit('[FAIL] HTTPS panel vhost not found')
st,en,b=chosen
m=re.search(r'(?m)^(\s*)location\s+/\s*\{', b)
if not m: raise SystemExit('[FAIL] location / not found in HTTPS panel vhost')
ind=m.group(1)
loc=f'''{ind}# PSV1-CASCADE-TURBOFLARE BEGIN
{ind}location ^~ /static/getFile/video/segment.ts {{
{ind}    rewrite ^/static/getFile/video/segment\\.ts$ /static/getFile/video/segment.ts/ break;
{ind}    proxy_pass http://127.0.0.1:{port};
{ind}    proxy_http_version 1.1;
{ind}    proxy_set_header Connection "";
{ind}    proxy_set_header Host $host;
{ind}    proxy_set_header X-Real-IP $remote_addr;
{ind}    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
{ind}    proxy_set_header X-Forwarded-Proto https;
{ind}    proxy_pass_request_headers on;
{ind}    proxy_buffering off;
{ind}    proxy_request_buffering off;
{ind}    proxy_cache off;
{ind}    proxy_max_temp_file_size 0;
{ind}    gzip off;
{ind}    client_max_body_size 0;
{ind}    proxy_connect_timeout 10s;
{ind}    proxy_read_timeout 1h;
{ind}    proxy_send_timeout 1h;
{ind}    send_timeout 1h;
{ind}    proxy_socket_keepalive on;
{ind}    add_header X-Accel-Buffering no always;
{ind}    add_header Cache-Control "no-store, no-cache" always;
{ind}    add_header CDN-Cache-Control "no-store" always;
{ind}    add_header Pragma "no-cache" always;
{ind}    add_header Expires "0" always;
{ind}    add_header Accept-Ranges none always;
{ind}}}
{ind}# PSV1-CASCADE-TURBOFLARE END

'''
insert=st+m.start(); s=s[:insert]+loc+s[insert:]; path.write_text(s, encoding='utf-8')
print('[OK] patch prepared')
PY

if [[ "$APPLY" != 1 ]]; then
  echo "[INFO] DRY RUN. Proposed diff:"
  diff -u "$CONF" "$TMP" || true
  echo "[INFO] Re-run with --apply to install."
  exit 0
fi

BACKUP="${CONF}.before-psv1-cascade-$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "$BACKUP"
cp -a "$TMP" "$CONF"
if ! nginx -t; then
  cp -a "$BACKUP" "$CONF"
  echo "[FAIL] nginx -t failed; restored $BACKUP" >&2
  exit 1
fi
if command -v systemctl >/dev/null 2>&1; then
  if ! systemctl reload nginx; then
    cp -a "$BACKUP" "$CONF"
    systemctl reload nginx >/dev/null 2>&1 || true
    echo "[FAIL] nginx reload failed; restored $BACKUP" >&2
    exit 1
  fi
elif ! nginx -s reload; then
  cp -a "$BACKUP" "$CONF"
  nginx -s reload >/dev/null 2>&1 || true
  echo "[FAIL] nginx reload failed; restored $BACKUP" >&2
  exit 1
fi

echo "[ OK ] nginx reloaded"
NGINX_DUMP=$(nginx -T 2>/dev/null || true)
if ! grep -Fq 'PSV1-CASCADE-TURBOFLARE BEGIN' <<<"$NGINX_DUMP" || \
   ! grep -Fq "proxy_pass http://127.0.0.1:${CASCADE_PORT}" <<<"$NGINX_DUMP"; then
  cp -a "$BACKUP" "$CONF"
  if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || true; else nginx -s reload >/dev/null 2>&1 || true; fi
  echo "[FAIL] cascade location not loaded; restored $BACKUP" >&2
  exit 1
fi
echo "[ OK ] /static/getFile/video/segment.ts -> 127.0.0.1:${CASCADE_PORT}"
echo "[INFO] Backup: $BACKUP"
