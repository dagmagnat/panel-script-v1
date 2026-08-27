## 1.2.5
- Добавлен явный opt-in `PSV1_ALLOW_PARENT_CDN=1` для TurboFlare parent-zone схем, когда вся DNS-зона уже обслуживается авторитетными NS CDN. По умолчанию защита v1.2.4 остаётся включённой.
- Добавлен автоматический локальный nginx bridge для TurboFlare cascade на RUS relay: `/static/getFile/video/segment.ts` проксируется из HTTPS vhost Remnawave Panel в `127.0.0.1:7443`.
- Исправляется сценарий TurboFlare, где origin задаётся только IP:443 и запрос с Host CDN-домена раньше попадал в panel `default_server` и возвращал JSON 404.
- nginx patch создаёт backup, проверяет `nginx -t`, делает reload и откатывается при ошибке.
- Добавлен standalone `cascade-nginx-fix.sh` как fallback для уже установленного relay.
- Сохранены исправления v1.2.4 для Remnawave 3.3.0 bridge-user, API discovery и user visibility.
