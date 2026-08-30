# Отчёт по исправлению каскада — v1.2.6

## Что было сломано

1. Архив назывался hotfix v1.2.5, но основной `install.sh` оставался v1.2.3. Исправления существовали только в отдельном патчере и не были встроены в проект.
2. Bridge-user считался ошибочным, если короткий ответ `POST/PATCH /api/users` не содержал `activeInternalSquads`, даже когда запись реально создавалась.
3. Существующий Internal Squad мог читаться как summary без `inbounds`; последующее обновление рисковало потерять ранее добавленные inbound в multi-exit схеме.
4. Node assignment считался успешным по форме ответа, без подтверждения Active Profile/Active Inbounds.
5. TurboFlare `IP:443` на совмещённом panel+relay всё ещё блокировался старым guard, поэтому добавленный nginx bridge был недостижим.
6. Проверка `nginx -T | grep -q` работала под `set -o pipefail` ненадёжно; некоторые ошибки reload/post-check не откатывали конфиг.
7. Любой существующий объект на порту `8888` мог быть ошибочно переиспользован как `BRIDGE_IN`.

## Что изменено

- исправления v1.2.4/v1.2.5 встроены в полный `install.sh` v1.2.6;
- bridge-user и его squad membership подтверждаются повторным `GET`, с fallback через Internal Squad bulk-action;
- squad сливается только после чтения detail endpoint и проверяется повторно;
- exit/relay assignment подтверждается read-after-write;
- добавлен обязательный post-check relay, exits, squad, users UUID и routing;
- TurboFlare nginx bridge создаётся и проверяется **до** изменений API;
- nginx patch полностью откатывается при syntax/reload/post-check ошибке;
- несовместимый inbound на `:8888` останавливает мастер;
- добавлены сценарные тесты с моками ответов API.

## Проверено локально

```text
bash -n install.sh                         PASS
bash -n cascade-nginx-fix.sh               PASS
bash -n tests/cascade-tests.sh              PASS
bash tests/cascade-tests.sh                 13 checks PASS
```

Живой end-to-end тест требует доступа к вашей Remnawave, relay, exit и CDN и в локальной среде не выполнялся. После установки успешная автоматическая конфигурация должна завершиться статусом `api-verified`; сетевое плечо relay → exit дополнительно проверяется командой из созданного `VERIFY.txt`.
