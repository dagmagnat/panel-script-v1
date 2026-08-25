# panel-script-v1

Универсальный Bash-установщик для настройки **Remnawave** и **3x-ui** с CDN/XHTTP.

Цель проекта — максимально автоматизировать установку, но при этом явно показывать пользователю, что скрипт сделал сам и какие действия нужно выполнить вручную в кабинете CDN/DNS.

> Текущая версия README рассчитана на `panel-script-v1 1.1.9`.

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

Remnawave поддерживает схему **центральная панель + несколько удалённых нод**. Для каждой ноды рекомендуется использовать один CDN-метод.

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
chmod 700 /root/panel-script-v1.sh && \
/root/panel-script-v1.sh
```

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
chmod 700 /root/panel-script-v1.sh
```

Проверить версию:

```bash
/root/panel-script-v1.sh --version
```

## Основные команды

```bash
/root/panel-script-v1.sh                 # обычный запуск / продолжение
/root/panel-script-v1.sh --manage-remna  # управление существующей Remnawave
/root/panel-script-v1.sh --check-remna   # проверка Remnawave
/root/panel-script-v1.sh --status        # сохранённый статус и результат
/root/panel-script-v1.sh --version       # версия
/root/panel-script-v1.sh --help          # справка
/root/panel-script-v1.sh --update        # обновить install.sh из GitHub
/root/panel-script-v1.sh --reset         # сбросить только ответы/прогресс установщика
/root/panel-script-v1.sh --node-credentials  # изменить Node Port / SECRET_KEY
```

`--reset` **не удаляет** установленную панель, Docker, nginx, ноду или другие программы.

## Как выглядит работа скрипта

В новых версиях действия разделены по смыслу:

- `[ПОДГОТОВКА]` — что пользователь должен сделать в DNS/CDN до продолжения;
- `[АВТО]` — что скрипт успешно создал или изменил сам;
- `[ВРУЧНУЮ]` — что осталось сделать руками;
- `[ПРОВЕРКА]` — контрольные команды и ожидаемый результат;
- `[ОСТОРОЖНО]` — действие может повлиять на уже работающую конфигурацию.

Если API панели не позволяет выполнить отдельный шаг автоматически, скрипт не должен молча пропускать его: в конце создаётся инструкция с точными действиями для пользователя.

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

Существующие профили, Hosts и Squads не должны удаляться без явного подтверждения пользователя.

Пользователи автоматически не переносятся между Internal Squads без подтверждения.

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

## Важный принцип проекта

У каждого CDN свои параметры XHTTP, origin, path, cache, HTTP-методы и ограничения. Пресеты нельзя без проверки копировать между провайдерами.

Если после автоматической части остаётся действие в панели CDN, DNS или Remnawave, скрипт должен показать его пользователю отдельным заметным блоком и сохранить в итоговой инструкции.
