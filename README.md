# panel-script-v1

Универсальный Bash-установщик для настройки **Remnawave** и **3x-ui** с CDN/XHTTP.

Цель проекта — максимально автоматизировать установку, но при этом явно показывать пользователю, что скрипт сделал сам и какие действия нужно выполнить вручную в кабинете CDN/DNS.

> README описывает базовый сценарий `panel-script-v1`; текущая версия установщика в этом выпуске — `1.4.5`. В архиве лежит полный готовый `install.sh`; применять старые hotfix-файлы поверх него не нужно.

## Что поддерживается

### Remnawave

| CDN | Xray port |
|---|---:|
| VK Cloud | `10085` |
| Yandex Cloud | `4443` |
| Beeline / CDNvideo | `10086` |
| Timeweb | `10087` |
| Selectel | `10088` |
| TurboFlare | `10089` |

Remnawave поддерживает схему **центральная панель + несколько удалённых нод**. Одна Node может держать несколько CDN-методов в одном активном Config Profile. Для каждого метода нужны свой порт и свой origin-vhost; при каскаде — свой `inboundTag` и свои outbound/balancer.

### 3x-ui

Поддерживаются только проверяемые пресеты:

- VK Cloud — `2053`
- Yandex Cloud — `4443`
- TurboFlare — `10089`

Beeline, Timeweb и Selectel для 3x-ui в проекте не считаются проверенными сценариями.

## Требования

- Ubuntu `22.04` или `24.04`
- запуск от `root`
- публичный IPv4
- домены/DNS в зависимости от выбранного CDN
- для Remnawave node — `SECRET_KEY` и тот же `Node Port`, который указан в панели

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/panel-script-v1/main/install.sh \
-o /root/panel-script-v1.sh && \
sed -i 's/\r$//' /root/panel-script-v1.sh && \
chmod 700 /root/panel-script-v1.sh && \
/root/panel-script-v1.sh
```

`sed` в команде убирает Windows-переносы CRLF, если GitHub отдал
`install.sh` в таком формате. Файл с обычными Linux-переносами LF команда не
изменяет.

Скрипт задаст вопросы и сохранит прогресс. Если установка остановилась на ошибке, после исправления просто запусти тот же файл снова.

```bash
/root/panel-script-v1.sh
```

## Обновление

Самый простой способ:

```bash
/root/panel-script-v1.sh --update
```

Или скачать свежий файл вручную:

```bash
curl -fsSL "https://raw.githubusercontent.com/dagmagnat/panel-script-v1/main/install.sh?nocache=$(date +%s)" \
-o /root/panel-script-v1.sh && \
sed -i 's/\r$//' /root/panel-script-v1.sh && \
chmod 700 /root/panel-script-v1.sh
```

Проверить версию:

```bash
/root/panel-script-v1.sh --version
```

Для Yandex direct и cascade используются разные URL paths: direct `/uploadfiles/`, cascade `/uploadfiles-cascade/`. Если каскадная команда попросит направить `/uploadfiles/` на relay-порт, установщик остановится и не изменит proxy-конфигурацию. Перед изменением Nginx/Caddy также проверяется TCP-доступность выбранного upstream.

## Основные команды

```bash
/root/panel-script-v1.sh                 # обычный запуск / продолжение
/root/panel-script-v1.sh --manage-remna  # управление существующей Remnawave
/root/panel-script-v1.sh --panel-cert pnl.example.com  # сертификат панели без остановки сервисов
/root/panel-script-v1.sh --cascade       # каскад: один exit или пул нескольких exit-нод
/root/panel-script-v1.sh --check-remna   # проверка Remnawave
/root/panel-script-v1.sh --status        # сохранённый статус и результат
/root/panel-script-v1.sh --version       # версия
/root/panel-script-v1.sh --help          # справка
/root/panel-script-v1.sh --update        # обновить install.sh из GitHub
/root/panel-script-v1.sh --reset         # сбросить только ответы/прогресс установщика
/root/panel-script-v1.sh --node-credentials  # изменить Node Port / SECRET_KEY
/root/panel-script-v1.sh --node-caddy-route turboflare file.example.ru 7443  # добавить XHTTP path, сохранив SFTPGo на /
```

`--reset` **не удаляет** установленную панель, Docker, nginx, ноду или другие программы.

## Сертификат уже работающей панели

Если панель или нода сообщает о self-signed certificate, на сервере центральной
панели выполни:

```bash
/root/panel-script-v1.sh --panel-cert pnl.example.com
```

Команда не использует `certbot --standalone`, не останавливает nginx и не
перезапускает Docker/Remnawave. Она:

1. проверяет DNS A-запись и единственный активный HTTPS-vhost нужного домена;
2. кладёт временный файл в `/var/www/certbot` и проверяет HTTP-01 локально и
   через публичный домен;
3. выпускает сертификат командой `certbot certonly --webroot`;
4. сохраняет точную резервную копию nginx-vhost;
5. заменяет только `ssl_certificate`/`ssl_certificate_key`, выполняет
   `nginx -t` и graceful reload;
6. проверяет TLS без `-k` и устанавливает deploy-hook для будущих продлений.

После graceful reload скрипт до 20 секунд ждёт, пока nginx начнёт отдавать
fingerprint именно нового сертификата. Это исключает ложный откат, если первое
соединение попало в старый worker сразу после reload.

При неоднозначном vhost, недоступном challenge, несовпадении DNS или ошибке
проверки команда прекращает работу. Если конфиг уже был переключён, он
автоматически восстанавливается из резервной копии.

## Как выглядит работа скрипта

В новых версиях действия разделены по смыслу:

- `[ПОДГОТОВКА]` — что пользователь должен сделать в DNS/CDN до продолжения;
- `[АВТО]` — что скрипт успешно создал или изменил сам;
- `[ВРУЧНУЮ]` — что осталось сделать руками;
- `[ПРОВЕРКА]` — контрольные команды и ожидаемый результат;
- `[ОСТОРОЖНО]` — действие может повлиять на уже работающую конфигурацию.

Если API панели не позволяет выполнить отдельный шаг автоматически, скрипт не должен молча пропускать его: в конце создаётся инструкция с точными действиями для пользователя.

## Remnawave Node: сначала только Node

Пункт `установить только Node` теперь всегда ставит только `remnanode`. Он не спрашивает CDN-метод, домены и Let's Encrypt, не ставит nginx, не занимает `80/443` и не меняет уже работающий Caddy/SFTPGo.

```text
3 — установить только Node (без CDN/nginx/Host)
```

После привязки Node и статуса Online запусти на сервере центральной панели `--manage-remna` для CDN-профиля/Host или `--cascade` для relay/exit. Ноду переустанавливать не нужно.

Старое незавершённое состояние `REMNA_ROLE=node` + CDN при повторном запуске автоматически переводится в node-only. Это не удаляет уже установленные программы.

### Два домена CDN: публичный и origin

- `CDN_DOMAIN` — адрес, который открывает клиент. Он ведёт на edge CDN.
- `ORIGIN_DOMAIN` — прямой домен источника. Он ведёт на VPS, и его имя передаётся CDN как Origin Host и SNI.

Пример со скриншота Yandex: `cloud.aer01.ru` — публичный CDN-домен, `file.aer01.ru` — origin Host/SNI. Если `https://file.aer01.ru/` открывает SFTPGo, то при отключённом кэше и правильных Host/SNI `https://cloud.aer01.ru/` должен показать тот же SFTPGo. Если видна заглушка, CDN обращается не к тому vhost: проверь Origin Host/SNI, а не переустанавливай Node.

Для TurboFlare делегированный домен — public/CDN, а `file.example.ru` — прямой домен проверки origin. В кабинете TurboFlare оставь Address=`IP_VPS:443` и HTTPS=`ON`: если форма не принимает домен, заменять IP не нужно. Origin-vhost на `:443` должен отдавать SFTPGo/заглушку на `/` и XHTTP только на специальном path.

Мастер создаёт готовую команду `APPLY-ON-NODE.sh` или `APPLY-ON-RELAY.sh`. Она вызывает `--node-proxy-route`, сама определяет Caddy либо nginx, создаёт backup, меняет только provider path, проверяет конфигурацию и делает reload с автоматическим откатом при ошибке. Поэтому корень сайта продолжает открывать SFTPGo/заглушку. Старый nginx upstream вроде `127.0.0.1:10089` автоматически переводится на фактический direct/cascade port (`7443–7448` для каскада).

Для нескольких CDN на одной ноде заведи отдельный origin-vhost/домен на каждый метод. Это обязательно для Beeline + TurboFlare: у них одинаковый XHTTP path, и один Host не может одновременно направлять его на два разных порта/exit. `--node-caddy-route` поэтому меняет только vhost с точным доменом и отказывается трогать чужой/default vhost.

### Панель и relay на одном VPS

Начиная с 1.2.3 такой сценарий защищён отдельным safe mode. Если на VPS уже обнаружена Remnawave panel, node-задача **не имеет права** очищать `sites-enabled`, включать self-signed bootstrap вместо панели, менять UFW или перезаписывать `/opt/remnawave/.env`. Переустановка существующей панели из нового мастера блокируется.

Если эта же нода потом выбрана как relay в `--cascade`, не запускай отдельный Caddy на `80/443`: эти порты уже занимает nginx панели. Для обычных CDN нужен отдельный домен/`server_name`, который в существующем nginx проксирует нужный path на method-specific relay port `127.0.0.1:7443–7448`. Начиная с v1.2.6 TurboFlare поддерживает и origin=`IP:443`: перед изменениями Remnawave мастер добавляет и проверяет только XHTTP-location в HTTPS `default_server` панели, не меняя `location /`.

Все основные нумерованные меню имеют `0 — назад`/`0 — выйти`, чтобы можно было вернуться при ошибочном выборе до изменений сервера.

## Remnawave: что автоматизируется

Для существующей ноды менеджер старается выполнить цепочку:

```text
Config Profile + Xray inbound
        ↓
Node + Active Inbound
        ↓
Internal Squad
        ↓
Host
        ↓
Xray JSON / шаблон подписки, если выбран
        ↓
External Squad, если он нужен выбранной схеме
```

Существующие профили, Hosts и Squads не удаляются. Новый CDN inbound добавляется в уже активный Config Profile ноды; перед merge сохраняется JSON-backup, а конфликт порта останавливает операцию. Начиная с 1.4.1 мастер также проверяет публичный endpoint `address:443:path`: если старый управляемый PSV1 Host мешает новому direct/cascade варианту, он отключается без удаления. Чужой Host автоматически не меняется.

Для каждого созданного Host мастер создаёт или переиспользует отдельный динамический Xray JSON template `PSV1 <Provider>` с `remnawave.addVirtualHostAsOutbound=true` и назначает его именно этому Host. Это выполняется и для обычного метода, и для каскада. Отдельный External Squad не требуется для Host-привязки и по умолчанию не создаётся.

Пользователи автоматически не переносятся между Internal Squads без подтверждения.

## Каскад

Каскад настраивается после установки и привязки чистых Node. Его можно добавить или повторно изменить без переустановки панели/ноды:

```bash
/root/panel-script-v1.sh --cascade
```

Порядок мастера фиксирован: метод CDN → relay → exit/пул → разные client/origin domains → аудит портов/Host → merge с backup → Active Inbounds/Internal Squad → Host/Xray JSON template → API post-check → публичная проверка XHTTP. Готовым ingress считается ответ HTTP `400`; `502`, `404` или отсутствие ответа не скрываются за успешным итогом.

Для Remnawave мастер сначала выбирает **relay-ноду**, затем предлагает режим exit:

```text
1 — одна exit-нода
2 — несколько exit-нод (пул)
```

В режиме пула можно выбрать несколько нод одной строкой, например `1,3,4`. Для первого теста доступны две стратегии Xray: `roundRobin` (по очереди) и `random` (случайный exit для нового соединения). `leastPing`/`leastLoad` автоматически не включаются, потому что для них требуется observatory.

Схема:

```text
клиент -> CDN -> RU relay
                  ├─ RU -> DIRECT
                  └─ остальное -> EXIT_POOL
                                  ├─ exit #1 :8888
                                  ├─ exit #2 :8888
                                  └─ exit #3 :8888
```

На каждой выбранной exit-ноде мастер добавляет/reuse `BRIDGE_IN :8888` в **активном** Config Profile и Active Inbounds, не удаляя существующие inbound. Для каждого exit создаётся отдельный bridge-user/VLESS UUID. На relay маршрут также объединяется с уже активным Config Profile. Порты разделены: TurboFlare `7443`, Beeline `7444`, Yandex `7445`, VK `7446`, Timeweb `7447`, Selectel `7448`. Каждое правило routing ограничено своим `inboundTag`, а outbound/balancer имеют уникальные имена. Поэтому один RU relay может направлять, например, Yandex в Germany, а TurboFlare в Netherlands, если хватает CPU/RAM/канала.

Если exit-нода не имеет активного Config Profile, создаваемый bridge-only профиль и inbound получают имя с методом, например `psv1-exit-bridge-yandex-…` и `BRIDGE_IN-yandex-…`. При повторном использовании совместимого `BRIDGE_IN :8888` для другого каскада отдельный listener не создаётся: один bridge может обслуживать несколько CDN-методов, и его исходное имя отражает метод, с которым он был создан.

Для reverse proxy на хосте relay inbound слушает `127.0.0.1`. Если Caddy/SFTPGo запущен в Docker, контейнер не видит host-loopback; в мастере нужно ввести Docker gateway этой сети, например `172.18.0.1`. Команда `--node-proxy-route` при выборе Caddy определяет этот gateway через `docker inspect`; для nginx на хосте использует `127.0.0.1`.

Записи через API проверяются повторным чтением. Короткий успешный ответ `POST/PATCH` сам по себе не считается доказательством: мастер перечитывает Node, Internal Squad и bridge-user, при необходимости использует squad bulk-action и только затем собирает `VLESS_EXIT`. Это важно для Remnawave 3.3.0, где ответы создания пользователя могут отличаться по набору полей.

В v1.2.7 исправлена совместимость bridge-user с Remnawave 3.3.0: обновление
пользователя выполняется по `username`, а выборочный fallback использует
`add-many-users` с числовым `userIds`. Endpoint `add-users`, добавляющий в squad
сразу всех пользователей панели, каскадом не вызывается.

В v1.2.8 после добавления relay inbound скрипт повторно подтверждает bridge-user
в окончательном составе squad. Финальный post-check умеет один раз безопасно
восстановить потерянное/запаздывающее членство и затем снова перечитать его.

В v1.2.9 post-check учитывает фактическую модель пользователя Remnawave 3.3.0:
API может возвращать numeric `id` и `uuid: null`. Успешное чтение по username,
VLESS UUID и членство в squad считаются достаточным подтверждением.

Балансируется выбор outbound для **новых соединений**. Это не bonding: один TCP-поток не складывает скорость нескольких VPS.

Существующий активный Profile relay не заменяется: мастер показывает merge, сохраняет backup и требует подтверждение. Provider-side DNS/origin и firewall/SG для `8888` остаются явными шагами. Для Caddy/nginx генерируется `APPLY-ON-RELAY.sh`, который не меняет `location /`. Сначала базовый CDN рекомендуется довести до `origin=400` и `CDN=400`, затем включать каскад.

Beeline и TurboFlare используют одинаковый XHTTP path. Поэтому на одном и том же origin-vhost этот URL нельзя одновременно направить на два разных порта. Скрипт обнаруживает такое совпадение и останавливается; безопасные варианты — отдельные origin-домены/vhost или отдельные RU relay. Остальные методы с разными path могут сосуществовать на одном relay при разных method-specific портах.

Yandex direct и Yandex cascade автоматически разделяются путями `/uploadfiles/` и `/uploadfiles-cascade/`. Их можно обслуживать одним клиентским CDN-доменом при условии, что CDN пропускает оба пути без rewrite/cache и origin reverse proxy маршрутизирует их соответственно на direct port и cascade port. APPLY-ON-RELAY.sh добавляет второй маршрут независимо и сохраняет существующий direct route.

Файлы каскада сохраняются в отдельном каталоге: `relay-profile.json`, `selected-exits.json`, `exit-pool.json`, `RELAY-STEPS.txt`, `EXIT-STEPS.txt`, `VERIFY.txt`, `MANUAL-ACTIONS.txt`.

Если relay был назначен автоматически, в конце выполняется обязательный API post-check: Active Profile/Inbound relay, Active Inbound каждой exit, полный состав `PSV1-CASCADE`, фактическое членство bridge-user, совпадение VLESS UUID и catch-all routing. При любой ошибке состояние записывается как `failed-postcheck`, а не как готовый каскад.

Для 3x-ui команда `--cascade` пока создаёт безопасный чек-лист. Автоматическая правка `xrayTemplateConfig`/SQLite намеренно не включена до отдельной живой проверки.

## Проверка исходников

```bash
bash -n install.sh
bash -n cascade-nginx-fix.sh
bash tests/panel-cert-tests.sh
bash tests/cascade-tests.sh
```

Тесты покрывают single/pool routing, короткие ответы Remnawave при создании и обновлении bridge-user, сохранение старых inbound в squad, read-after-write назначения ноды и отказ от несовместимого слушателя на `:8888`.

## Cloudflare

Cloudflare используется **по выбору**. Скрипт спрашивает, нужен ли он.

Если Cloudflare выбран, DNS-записи обычно должны быть `DNS only`, если конкретная инструкция CDN не говорит иначе.

Если Cloudflare не используется, те же A/CNAME записи нужно создать у своего DNS-провайдера.

## Результаты, логи и файлы

Основные пути:

```text
/root/.panel-script-v1/config.env      сохранённые ответы
/root/.panel-script-v1/install.log     лог установки
/root/panel-script-v1-output/          созданные JSON, инструкции и результаты
```

Для Remnawave дополнительные файлы конкретного метода создаются в:

```text
/root/panel-script-v1-output/remna-methods/
```

Там могут быть:

```text
profile.json
host.txt
xhttpExtraParams.json
provider-steps.txt
NEXT-STEPS.txt
MANUAL-ACTIONS.txt
```

## Удаление самого проекта

Чтобы удалить **только установщик, его состояние, логи и сгенерированные файлы**, не трогая установленную панель/ноду:

```bash
rm -f /root/panel-script-v1.sh
rm -rf /root/.panel-script-v1
rm -rf /root/panel-script-v1-output
```

Это **не удаляет** Remnawave, 3x-ui, Docker, nginx, сертификаты или созданные CDN-ресурсы.

Полное удаление панели специально не сделано одной универсальной командой: такой сценарий может уничтожить БД, пользователей и рабочие конфигурации и должен выполняться отдельно с резервной копией.

## Безопасность

Никогда не публикуй в GitHub и не отправляй посторонним:

- `SECRET_KEY` ноды;
- API token Remnawave;
- `.env` панели;
- пароли администратора и БД;
- приватные ключи сертификатов.

Если секрет случайно опубликован — создай/ротируй его заново.

Remnawave-администратор создаётся вручную в веб-интерфейсе. Скрипт может показать сгенерированную подсказку для первого логина, но **не устанавливает этот пароль в Remnawave и не знает фактический пароль**, если пользователь ввёл другой.

## Важный принцип проекта

У каждого CDN свои параметры XHTTP, origin, path, cache, HTTP-методы и ограничения. Пресеты нельзя без проверки копировать между провайдерами.

Если после автоматической части остаётся действие в панели CDN, DNS или Remnawave, скрипт должен показать его пользователю отдельным заметным блоком и сохранить в итоговой инструкции.
