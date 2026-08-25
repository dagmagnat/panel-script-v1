# panel-script-v1 — v1.1.6

## 1.1.6 API/node fallback

API token validation now accepts any successful 2xx JSON response instead of requiring one exact configProfiles wrapper. List parsers support array/items/data wrappers for profiles, nodes, hosts and internal squads. Host creation tries current `xhttpExtraParams` first and legacy `xHttpExtraParams` as fallback.

Универсальный установщик для Remnawave и 3x-ui с CDN/XHTTP-пресетами.


## Исправление 1.1.3 — менеджер существующей Remnawave

`--manage-remna` больше не требует, чтобы панель обязательно отвечала именно на `127.0.0.1:3000`. Менеджер пробует localhost, опубликованный Docker-порт, IP контейнера и сохранённый домен панели. Если API всё равно недоступен, мастер не завершается ошибкой: он просит URL панели или переходит в ручной режим и создаёт точные `profile.json`, `xhttpExtraParams.json`, `host.txt`, `provider-steps.txt` и `NEXT-STEPS.txt`.

Для каждого CDN обязательная цепочка в панели: **Config Profile с Xray inbound → профиль назначен Node → Active inbounds → Internal Squad → пользователь в этом Internal Squad → Host**. External Squads для базового XHTTP не обязательны и скрипт их не меняет.

## Главное изменение 1.1.0

Теперь существующую центральную Remnawave-панель не нужно переустанавливать ради нового CDN.
На сервере панели доступен режим:

```bash
/root/panel-script-v1.sh --manage-remna
```

Он:

- находит уже установленную локальную Remnawave;
- показывает ноды, которые уже заведены в панели;
- предлагает один из 6 CDN: VK, Yandex, Beeline/CDNvideo, Timeweb, Selectel, TurboFlare;
- спрашивает только параметры нужного метода;
- создаёт отдельный Config Profile с уникальным inbound-tag;
- назначает профиль выбранной ноде и включает inbound (если это безопасно);
- добавляет inbound в выбранный Internal Squad, не удаляя старые;
- если Squad ещё нет — предлагает создать `PSV1-CDN`;
- создаёт Host, если CDN-домен уже известен;
- не создаёт дубликат Host при повторном запуске;
- сохраняет готовые JSON и инструкции в `/root/panel-script-v1-output/remna-methods/`;
- если API конкретной версии Remnawave не принимает автоматический шаг, не удаляет существующие настройки, а оставляет готовый файл и ручной шаг.

Рекомендуемая архитектура: одна центральная Remnawave-панель + отдельный VPS на каждый CDN-метод. Несколько нод и методов могут быть активны одновременно.

## Если центральная панель уже установлена, а нод пока нет

1. В Remnawave открой `Nodes` → `Create node`.
2. В `Address` укажи IPv4 европейского VPS, `Node Port` выбери в панели (например `2222` или `2233`) и введи ТО ЖЕ значение в установщике ноды.
3. Сохрани и скопируй `SECRET_KEY`.
4. На европейском VPS запусти этот же `install.sh`.
5. Выбери `Remnawave` → `только нода` → нужный CDN.
6. Введи IP центральной панели и `SECRET_KEY`.
7. После установки ноды вернись на сервер панели и выполни:

```bash
/root/panel-script-v1.sh --manage-remna
```

8. Выбери ноду и тот же CDN. Менеджер подготовит/создаст Profile → Active inbound → Squad → Host.
9. Выполни показанные шаги в кабинете самого CDN-провайдера.

Для TurboFlare важное найденное на практике поле: `Сайты → домен → Редактирование → Адрес = IP_НОДЫ:443`, HTTPS к источнику включён, устаревший кэш выключен. После делегирования сам CDN-домен должен резолвиться в edge TurboFlare, а не в IP ноды.

## Одна команда с публичного GitHub

После загрузки `install.sh` в `dagmagnat/panel-script-v1`:

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/panel-script-v1/main/install.sh -o /root/panel-script-v1.sh && chmod 700 /root/panel-script-v1.sh && /root/panel-script-v1.sh
```

Обновление уже скачанного установщика:

```bash
/root/panel-script-v1.sh --update
```

Проверить версию:

```bash
/root/panel-script-v1.sh --version
```

Менеджер существующей Remnawave:

```bash
/root/panel-script-v1.sh --manage-remna
```

Проверка панели:

```bash
/root/panel-script-v1.sh --check-remna
```

## Поддерживаемые методы

Remnawave: VK Cloud, Yandex Cloud, Beeline/CDNvideo, Timeweb, Selectel, TurboFlare.

3x-ui: VK Cloud, Yandex Cloud, TurboFlare. Для 3x-ui используется совместимый сценарий v3.3.1.

## Безопасность

Не клади в публичный GitHub пароли, `SECRET_KEY`, API tokens, `.env` или UUID пользователей. Секреты вводятся на VPS. Менеджер Remnawave может попросить логин/пароль администратора для локальной API-авторизации; пароль не сохраняется. Полученный токен хранится только локально в `/root/.panel-script-v1/` с правами root.


## Node Port

Node Port настраивается в карточке ноды Remnawave и может отличаться от 2222. Установщик спрашивает его отдельно. Значение в панели и `NODE_PORT` контейнера должны совпадать.

## API token Remnawave: важное отличие

В окне сведений API Token поле **UUID** — это идентификатор записи, а не секретный token для `Authorization`. Для менеджера нужен именно секретный API token, который выдаётся при создании токена. Скрипт 1.1.3 распознаёт UUID, принимает как чистый token, так и строку с префиксом `Bearer `, и при ошибке показывает HTTP-код вместо аварийного завершения.


## Remnawave API: список нод

Начиная с v1.1.5 менеджер не предполагает один фиксированный JSON-wrapper для `GET /api/nodes`. Он ищет массив объектов нод рекурсивно и сохраняет сырой ответ API в `/root/panel-script-v1-output/remna-methods/last-nodes-response.json`. Это устраняет ложное сообщение «в панели нет нод», когда Node видна и Connected в интерфейсе.

External Squads не входят в обязательную цепочку обычного CDN/XHTTP. Для базовой схемы нужны Config Profile/Xray inbound → Node/Active Inbounds → Internal Squad → User → Host. External Squad используется только при отдельной reseller/multi-tenant логике подписок и автоматически не создаётся.

### Если Node видна в панели, а API token не возвращает `/api/nodes`

В v1.1.6 это больше не считается «панель пустая». Скрипт показывает HTTP-диагностику и предлагает временно войти обычным логином/паролем администратора. Полученный admin JWT используется только для текущего мастера, чтобы прочитать Node и выполнить безопасное добавление Profile/Inbound/Internal Squad/Host.

