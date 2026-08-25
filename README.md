# panel-script-v1

Интерактивный установщик для Ubuntu 22.04/24.04.

Он предназначен для установки и настройки:

- **Remnawave**: отдельная панель, отдельная нода или панель + нода;
- **Remnawave CDN-методы**: VK Cloud, Yandex Cloud, Beeline/CDNvideo, Timeweb, Selectel, TurboFlare;
- **3x-ui v3.3.1**: VK Cloud, Yandex Cloud, TurboFlare;
- nginx-origin, XHTTP, BBR, UFW, сертификаты, сайт-заглушка и диагностические проверки.

> Важно: у каждого CDN свои параметры. Установщик хранит отдельные preset'ы и не смешивает настройки разных CDN.

## Самый простой запуск на новом VPS

После того как репозиторий `dagmagnat/panel-script-v1` создан как **Public** и файл `install.sh` загружен в ветку `main`, просто вставь на VPS **одну команду**:

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/panel-script-v1/main/install.sh -o /root/panel-script-v1.sh && chmod 700 /root/panel-script-v1.sh && /root/panel-script-v1.sh
```

Запускать от `root`.

Скрипт сохраняется на сервере в:

```text
/root/panel-script-v1.sh
```

Поэтому повторно скачивать его не нужно.

## Повторный запуск

```bash
/root/panel-script-v1.sh
```

Если установка ранее остановилась, скрипт предложит продолжить с сохранёнными ответами.

Показать статус:

```bash
/root/panel-script-v1.sh --status
```

Сбросить только ответы установщика, **не удаляя установленную панель/ноду**:

```bash
/root/panel-script-v1.sh --reset
```

Обновить `install.sh` из этого GitHub-репозитория и сразу запустить:

```bash
/root/panel-script-v1.sh --update
```

## Если нужна только Remnawave-нода

На каждом новом VPS запускается **этот же** `install.sh`.

В меню выбирай:

```text
Remnawave
→ Только нода Remnawave
→ версия, совпадающая с центральной панелью
→ нужный CDN
```

До запуска node-only нужно в центральной Remnawave-панели создать новую Node и получить её `SECRET_KEY`.

Установщик попросит:

```text
IP сервера центральной панели
SECRET_KEY ноды
CDN/origin параметры выбранного метода
```

После установки готовые файлы для центральной панели находятся в:

```text
/root/panel-script-v1-output/
```

Там будут, в зависимости от CDN:

```text
remnawave-profile-*.json
remnawave-host-extra-*.json
remnawave-host-*.txt
provider-steps-*.txt
result.txt
```

## Если нужна только центральная Remnawave-панель

Выбирай:

```text
Remnawave
→ Панель Remnawave
```

В этом режиме установщик **не спрашивает CDN** и не создаёт XHTTP-ноду. После установки центральной панели на других VPS запускай тот же скрипт и выбирай `Только нода`.

## Панель + нода на одном VPS

Выбирай:

```text
Remnawave
→ Панель + нода на одном сервере
```

Сначала поднимется панель. Затем установщик попросит открыть её, создать Node на порт `2222`, скопировать `SECRET_KEY` и продолжить установку ноды.

## TurboFlare

В установщик внесено найденное на практике исправление. В TurboFlare необходимо проверить:

```text
Сайты → нужный сайт → Редактирование
Адрес: IP_НОДЫ:443
Использовать HTTPS при запросе к источникам: ВКЛ
Устаревший кэш при недоступности источника: ВЫКЛ
```

После делегирования CDN-домен должен резолвиться в edge TurboFlare, а не в IP ноды. IP ноды задаётся в поле источника/`Адрес`.

## Как загрузить эти файлы на GitHub через сайт

Если репозитория ещё нет:

1. Открой GitHub и войди в аккаунт `dagmagnat`.
2. В правом верхнем углу нажми **`+`**.
3. Выбери **`New repository`**.
4. В `Repository name` введи **`panel-script-v1`**.
5. Выбери **`Public`**.
6. Нажми **`Create repository`**.
7. В репозитории нажми **`Add file` → `Upload files`**.
8. Перетащи туда `install.sh` и `README.md`.
9. Внизу нажми **`Commit changes`**.

После этого команда из раздела «Самый простой запуск» начнёт работать.

## Что нельзя загружать в Public GitHub

Не добавляй в репозиторий:

- `SECRET_KEY` нод;
- пароли панелей;
- API tokens;
- `.env` с рабочими секретами;
- содержимое `/root/.panel-script-v1/`;
- содержимое `/root/panel-script-v1-output/` с реальными данными серверов.

Сам `install.sh` секретов не содержит: он спрашивает их уже во время установки на VPS.

## Где смотреть лог

```text
/root/.panel-script-v1/install.log
```

Сохранённые ответы:

```text
/root/.panel-script-v1/config.env
```

Они остаются только на VPS и в GitHub не отправляются.
