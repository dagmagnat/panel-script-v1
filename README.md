# panel-script-v1 — v1.1.0

Универсальный установщик для Remnawave и 3x-ui с CDN/XHTTP-пресетами.

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
2. В `Address` укажи IPv4 европейского VPS, `Port` = `2222`.
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
