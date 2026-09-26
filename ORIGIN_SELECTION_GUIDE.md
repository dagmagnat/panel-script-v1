# Руководство: Выбор типа Origin для методов CDN

## Что изменилось

При добавлении метода CDN в panel-script-v1 (версия 1.4.5+) вы теперь можете выбрать **тип origin**:

### 1. Заглушка (Placeholder)
- Простой веб-сайт, размещённый на целевой ноде
- Находится в `/var/www/cdn-placeholder`
- Используется для тестирования CDN конфигурации
- Минимальные требования к серверу

### 2. SFTP Go
- Полнофункциональный web-интерфейс для хранения и управления файлами
- Может быть запущен как Docker контейнер или системный сервис
- Предоставляет web-интерфейс на порту (по умолчанию 8080)
- Позволяет загружать/скачивать файлы через web

## Процесс выбора

Когда вы запускаете `./install.sh --manager` и выбираете метод CDN (например, Timeweb):

```
Какой CDN добавить в существующую панель?
  1 — VK Cloud
  2 — Yandex Cloud
  3 — Beeline / CDNvideo
  4 — Timeweb          ← выбираете
  5 — Selectel
  6 — TurboFlare
```

После выбора метода появляется новое меню:

```
Шаг 1: Выбор типа origin для Timeweb
Тип origin (что будет доступно по CDN):
  1 — Заглушка (placeholder website)
  2 — SFTP Go (web-интерфейс хранилища файлов)
  0 — Назад

Выбор [1]: 
```

## Конфигурация для каждого метода

| Метод | Placeholder | SFTP Go |
|-------|-------------|---------|
| VK Cloud | :80 | :8080 |
| Yandex Cloud | :443 | :8080 |
| Beeline | :443 | :8080 |
| Timeweb | :80 | :8080 |
| Selectel | :443 | :8080 |
| TurboFlare | :443 | :8080 |

Все порты работают локально: `127.0.0.1:PORT`

## Примеры конфигурации

### Пример 1: Timeweb с Заглушкой

```bash
Шаг 1: Выбор метода CDN → 4 (Timeweb)
Шаг 2: Выбор типа origin → 1 (Заглушка)
Шаг 3: Ввод CDN домена → cdn.example.com
```

**Результат:**
- Origin слушает: `127.0.0.1:80` (веб-заглушка)
- Nginx проксирует: `/content/media/` → `127.0.0.1:80`
- CDN домен: `cdn.example.com`
- Тип: легче всего для тестирования

### Пример 2: VK Cloud с SFTP Go

```bash
Шаг 1: Выбор метода CDN → 1 (VK Cloud)
Шаг 2: Выбор типа origin → 2 (SFTP Go)
Шаг 3: Ввод origin домена → origin.example.net
Шаг 4: Ввод CDN домена → cdn.example.net
```

**Результат:**
- Origin слушает: `127.0.0.1:8080` (SFTP Go web-интерфейс)
- Nginx проксирует: `/content/media/stream/` → `127.0.0.1:8080`
- CDN домен: `cdn.example.net`
- Тип: полнофункциональное хранилище файлов

## Установка SFTP Go

Если вы выбрали SFTP Go, нужно установить его на целевой ноде:

### Вариант 1: Docker

```bash
docker run -d \
  --name sftpgo \
  -p 8080:8080 \
  -e SFTPGO_HTTPD_BINDINGS__0__PORT=8080 \
  drakkan/sftpgo:latest
```

### Вариант 2: Системный сервис

```bash
# Загрузить SFTP Go
wget https://github.com/drakkan/sftpgo/releases/download/v2.x.x/sftpgo_linux_amd64.tar.gz
tar xzf sftpgo_linux_amd64.tar.gz
cd sftpgo

# Запустить
./sftpgo serve
```

После запуска SFTP Go будет доступен на:
- Web-интерфейс: `http://127.0.0.1:8080`
- SFTP: `sftp://127.0.0.1:2022`

## Инструкции для CDN-провайдера

После выбора типа origin скрипт генерирует файл с инструкциями, которые включают:

```
Origin конфигурация:
  Тип: placeholder
  Адрес: 127.0.0.1:80
  Примечание: На целевой ноде работает веб-заглушка (/var/www/cdn-placeholder)
```

или

```
Origin конфигурация:
  Тип: sftpgo
  Адрес: 127.0.0.1:8080
  Примечание: На целевой ноде должен быть установлен SFTP Go web-интерфейс
```

## Поддерживаемые методы CDN

Все 6 методов поддерживают оба типа origin:

1. **VK Cloud** - proxy_pass на `:80` (placeholder) или `:8080` (SFTP Go)
2. **Yandex Cloud** - proxy_pass на `:443` (placeholder) или `:8080` (SFTP Go)
3. **Beeline / CDNvideo** - proxy_pass на `:443` (placeholder) или `:8080` (SFTP Go)
4. **Timeweb** - proxy_pass на `:80` (placeholder) или `:8080` (SFTP Go)
5. **Selectel** - proxy_pass на `:443` (placeholder) или `:8080` (SFTP Go)
6. **TurboFlare** - proxy_pass на `:443` (placeholder) или `:8080` (SFTP Go)

## Переменные окружения

После конфигурации доступны переменные:

```bash
ORIGIN_TYPE     # "placeholder" или "sftpgo"
ORIGIN_PORT     # 80, 443 или 8080 (в зависимости от выбора)
ORIGIN_SCHEME   # "http"
ORIGIN_DOMAIN   # domain name (если указан)
CDN_DOMAIN      # CDN domain (если указан)
```

## Переключение между типами

Если вы захотите изменить тип origin позже:

```bash
# Запустить менеджер заново
./install.sh --manager

# Выбрать тот же метод
# Выбрать другой тип origin
# Переконфигурировать конфиг CDN-провайдера
```

## Решение проблем

### SFTP Go не работает

1. Проверьте, запущен ли сервис:
```bash
curl http://127.0.0.1:8080
```

2. Если используется Docker:
```bash
docker ps | grep sftpgo
docker logs sftpgo
```

3. Проверьте правильность порта в конфиге

### Заглушка показывает ошибку 404

1. Проверьте, существует ли `/var/www/cdn-placeholder`:
```bash
ls -la /var/www/cdn-placeholder
```

2. Проверьте права доступа:
```bash
chmod -R 755 /var/www/cdn-placeholder
```

## Примечания

- **Единый порт SFTP Go**: текущая конфигурация использует порт 8080 для всех методов
- Можно изменить порты в функции `rm_manager_get_origin_port()` в `install.sh`
- SFTP Go может работать на одной ноде для нескольких методов CDN
- Placeholder всегда находится в `/var/www/cdn-placeholder` независимо от метода
