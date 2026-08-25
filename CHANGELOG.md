# Changelog

## 1.1.9
- Новый цветной UX мастера: `[ПОДГОТОВКА]`, `[АВТО]`, `[ВРУЧНУЮ]`, `[ПРОВЕРКА]`, `[ОСТОРОЖНО]`. Ручные действия больше не теряются в общем белом выводе.
- Cloudflare возвращён как явный выбор `да/нет`; при `нет` те же DNS-действия показываются для текущего DNS-провайдера без proxy/CDN-ускорения.
- Перед изменениями сервера/панели показывается провайдер-специфичная подготовка для VK, Yandex, Beeline/CDNvideo, Timeweb, Selectel и TurboFlare.
- В конце всегда формируются отдельные блоки «что сделано автоматически» и «что осталось вручную», плюс `MANUAL-ACTIONS.txt`.
- Для Remnawave manager добавлена автоматизация `Подписка -> Xray JSON`: отдельный XRAY_JSON шаблон для метода, `remnawave.addVirtualHostAsOutbound=true`, попытка назначить шаблон созданному Host через `xrayJsonTemplateUuid`, перенос Default вниз списка.
- Добавлена автоматизация отдельного External Squad и привязки Xray JSON шаблона. Массовое назначение всех пользователей остаётся только по отдельному подтверждению.
- Удаление Default Xray JSON никогда не выполняется молча: отдельное красное предупреждение, default = NO, удаление только после успешного отдельного шаблона/External Squad.
- Selectel и Beeline теперь при необходимости останавливают мастер на понятном шаге и просят технический CDN-домен до создания Host.
- Слой Xray JSON/External Squad основан на API Remnawave, но ещё не прошёл живой тест именно на панели 3.3.0; при несовпадении API основной Profile/Node/Internal Squad/Host не откатывается, а выводится ручной пункт.

## 1.1.8
- Исправлен `unbound variable: path` в API helper при `set -u`.
- `rm_api` и `rm_api_fetch_to_file` теперь инициализируют `path` до построения URL.
- Создание Config Profile снова доходит до реального POST и сохраняет HTTP/JSON-диагностику при отказе API.

## 1.1.7

- Исправлено создание Config Profile в Remnawave: имя профиля теперь всегда не длиннее 30 символов — это лимит API.
- Раньше имя вида `psv1-turboflare-turboflare-ccb671` имело 33 символа и могло быть отклонено API до создания профиля.
- При ошибке `POST /api/config-profiles` менеджер теперь показывает HTTP-код, фактическую длину имени и тело ответа API вместо одной общей строки «API не создал профиль».
- Существующие профили/ноды/хосты по-прежнему не удаляются и не перезаписываются автоматически.

## 1.1.6

- Исправлено неверное заключение «API действительно не вернул ни одной ноды», когда `GET /api/nodes` фактически отдавал пустое тело/невалидный JSON.
- Менеджер сохраняет HTTP-код и размер ответа в `last-nodes-http.txt` и больше не считает пустой файл доказательством отсутствия нод.
- Для списка нод пробуются `/api/nodes`, `/api/nodes?start=0&size=100` и `/api/nodes?start=0&size=1000`.
- Если API token работает для панели, но список нод через него не приходит, мастер предлагает безопасный fallback: получить временный admin JWT через логин/пароль и продолжить автоматическую настройку.
- Добавлена нормализация полей ноды `address/nodeAddress/host/ip`, `port/nodePort`, `isConnected/is_connected/connected`.
- Вторую ноду скрипт больше не предлагает создавать при пустом/невалидном ответе API.

## 1.1.5

- Исправлено ложное «в панели нет ни одной ноды» при Remnawave 3.3.x: менеджер больше не зависит от одного JSON-wrapper ответа `GET /api/nodes`.
- Парсеры Nodes / Config Profiles / Hosts / Internal Squads теперь находят сущности по структуре объектов, включая вложенные/paginated wrappers.
- Сырые ответы API сохраняются локально в `/root/panel-script-v1-output/remna-methods/last-*-response.json` для диагностики без повторного ввода токена.
- Если API содержит node-like объект, но парсер не смог его разобрать, скрипт больше не утверждает, что панель пустая, и ничего не создаёт вслепую.
- Уточнено: External Squads не обязательны для базового XHTTP/CDN и не создаются автоматически; обязательна цепочка Profile/Inbound → Node Active Inbounds → Internal Squad → User → Host.

# 1.1.4

- Fixed false API-token rejection when `/api/config-profiles` returns HTTP 200 with a newer response wrapper.
- Added tolerant list parsing for profiles, nodes, hosts and internal squads.
- Host API now prefers `xhttpExtraParams` and falls back to legacy `xHttpExtraParams`.
- Existing panel data is still never deleted automatically.

# 1.1.3

- Исправлен аварийный выход `код 2` при отклонённом API token.
- Добавлена поддержка token с/без префикса `Bearer `.
- UUID записи API Token теперь распознаётся и не принимается за секретный token.
- Проверка `/api/config-profiles` принимает несколько форм ответа API и показывает HTTP-код ошибки.

# Changelog

## 1.1.2

- Исправлен `--manage-remna`: v1.1.1 ошибочно считал панель отсутствующей, если API не отвечал именно на `127.0.0.1:3000`.
- `--manage-remna` теперь загружает сохранённый `PANEL_DOMAIN`.
- Автообнаружение API: localhost:3000 → опубликованный Docker-порт → IP контейнера `remnawave`/`remnawave-rest-api` → сохранённый HTTPS/HTTP домен панели.
- Если API не найден, мастер больше не завершается: можно ввести URL панели или получить безопасный ручной комплект.
- `NEXT-STEPS.txt` создаётся всегда, даже при автоматической настройке. В нём перечислены Config Profile/Xray inbound → Node/Active Inbounds → Internal Squad → Users → Host → CDN provider.
- Явно указано, что External Squads не требуются для базового XHTTP/CDN и не изменяются автоматически.
- Убраны ещё несколько потенциальных `SIGPIPE/141` в менеджере.

## 1.1.1

- Исправлен аварийный выход с кодом 141 сразу после `Xray 26.7.28`: причиной был `xray version | head -1` вместе с `set -o pipefail`.
- Remnawave Node Port больше не зашит как 2222. Установщик спрашивает точный порт из карточки ноды (например 2233) и использует его в `.env` и firewall.
- При продолжении незавершённой установки от старой версии, если Node Port не был сохранён, скрипт отдельно спрашивает его и продолжает без сброса остальных ответов.
- В подсказках panel-only/panel+node подчёркнуто: Node Port в панели и `NODE_PORT` контейнера должны совпадать.
- Добавлен `--node-credentials`, чтобы безопасно заменить Node Port/SECRET_KEY без сброса остальных ответов.

## 1.1.0

- Добавлен безопасный менеджер уже установленной Remnawave: `--manage-remna`.
- Панель-only больше не требует выбора CDN: CDN выбирается при установке ноды и затем привязывается к ней через менеджер панели.
- Добавление нового метода не удаляет существующие Profiles/Hosts/Squads.
- Уникальные inbound tags для разных нод/методов.
- Автосоздание Config Profile, назначение Profile/Active Inbound, добавление в Internal Squad и создание Host через локальную API панели.
- Если Internal Squad отсутствует, предлагается создать `PSV1-CDN`.
- Повторный запуск не создаёт дубликат Host.
- Fallback для нескольких вариантов PATCH API Remnawave 3.x.
- Исправлены пресеты менеджера: VK/Yandex имеют свою структуру xhttpSettings; TurboFlare не содержит лишний `sessionIDLength`; host `xhttpExtraParams` соответствует мануалам.
- Сохранено исправление TurboFlare origin: адрес ресурса = `IP_НОДЫ:443`.
- Сохранены исправления v1.0.1/v1.0.2: без конфликта ufw/iptables-persistent и более надёжный ACME nginx bootstrap.

## 1.0.2

- Исправлена проверка ACME webroot nginx.

## 1.0.1

- Убран конфликт `ufw` и `iptables-persistent` на Ubuntu 24.04.
