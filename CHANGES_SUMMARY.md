# Резюме изменений: Выбор Origin для методов CDN

## Цель
Добавить для каждого из 6 методов CDN возможность выбрать тип origin:
1. **Placeholder** (заглушка) - простой веб-сайт
2. **SFTP Go** - web-интерфейс хранилища файлов

## Измененные функции

### 1. Добавлена функция `method_title()` (строка 221-231)
Преобразует короткие названия методов в читаемый вид:
```bash
method_title "vk"        → "VK Cloud"
method_title "yandex"    → "Yandex Cloud"
method_title "beeline"   → "Beeline / CDNvideo"
method_title "timeweb"   → "Timeweb"
method_title "selectel"  → "Selectel"
method_title "turboflare" → "TurboFlare"
```

### 2. Добавлена функция `rm_manager_choose_origin_type()` (строка 783-799)
Интерактивное меню для выбора типа origin:
```
Тип origin (что будет доступно по CDN):
  1 — Заглушка (placeholder website)
  2 — SFTP Go (web-интерфейс хранилища файлов)
  0 — Назад
```
Возвращает: `placeholder` или `sftpgo`

### 3. Добавлена функция `rm_manager_get_origin_port()` (строка 802-831)
Возвращает порт для origin в зависимости от типа и метода CDN:
- **Placeholder**: порты по умолчанию для каждого метода
  - VK Cloud: 80
  - Yandex: 443
  - Beeline: 443
  - Timeweb: 80
  - Selectel: 443
  - TurboFlare: 443
- **SFTP Go**: единый порт 8080 для всех методов (или можно использовать разные)

### 4. Добавлена функция `rm_manager_get_origin_scheme()` (строка 834-841)
Возвращает схему (http/https) для origin:
- **Placeholder**: `http`
- **SFTP Go**: `http`

### 5. Обновлена функция `rm_manager_collect_domains()` (строка 854-909)
Теперь процесс выбора включает два шага:

**Шаг 1: Выбор типа origin**
- Вызывает `rm_manager_choose_origin_type()`
- Получает порт через `rm_manager_get_origin_port()`
- Получает схему через `rm_manager_get_origin_scheme()`
- Сохраняет в переменные: `ORIGIN_TYPE`, `ORIGIN_PORT`, `ORIGIN_SCHEME`

**Шаг 2: Сбор доменов**
- Как раньше, но с учётом выбранного типа origin

**Шаг 3: Сводка конфигурации**
- Показывает метод, тип origin, адрес и домены

### 6. Обновлена функция `rm_manager_provider_steps()` (строка 1260+)
Теперь инструкции для CDN-провайдера включают:
- **Origin конфигурация**: тип (placeholder/sftpgo), адрес (127.0.0.1:порт)
- **Примечание** для каждого типа:
  - Placeholder: "На целевой ноде работает веб-заглушка (/var/www/cdn-placeholder)"
  - SFTP Go: "На целевой ноде должен быть установлен SFTP Go web-интерфейс"

## Поток взаимодействия

```
Выбор метода CDN (1-6)
    ↓
rm_manager_collect_domains()
    ├── Шаг 1: Выбор типа origin
    │   ├── rm_manager_choose_origin_type()
    │   ├── rm_manager_get_origin_port()
    │   └── rm_manager_get_origin_scheme()
    ├── Шаг 2: Сбор доменов (как раньше)
    └── Шаг 3: Сводка конфигурации
    ↓
Сохранение: ORIGIN_TYPE, ORIGIN_PORT, ORIGIN_SCHEME, ORIGIN_DOMAIN, CDN_DOMAIN
    ↓
Использование при конфигурации nginx/Caddy
    ├── proxy_pass http://127.0.0.1:$ORIGIN_PORT
    ├── Для placeholder: используется /var/www/cdn-placeholder
    └── Для SFTP Go: используется web-интерфейс на указанном порту
```

## Переменные среды

Для каждого метода после выбора доступны:
```bash
ORIGIN_TYPE     # "placeholder" или "sftpgo"
ORIGIN_PORT     # порт (зависит от типа и метода)
ORIGIN_SCHEME   # "http" или "https"
ORIGIN_DOMAIN   # домен origin (заполняется пользователем)
CDN_DOMAIN      # CDN домен (заполняется пользователем)
```

## Примеры использования

### Пример 1: VK Cloud с заглушкой
```
Метод: vk
Origin тип: placeholder
Origin адрес: 127.0.0.1:80
Origin домен: origin.example.net
CDN домен: cdn.example.net
```
→ nginx проксирует `/content/media/stream/` на `127.0.0.1:80` (заглушка)

### Пример 2: Timeweb с SFTP Go
```
Метод: timeweb
Origin тип: sftpgo
Origin адрес: 127.0.0.1:8080
Origin домен: (пусто)
CDN домен: cdn.example.net
```
→ nginx проксирует `/content/media/` на `127.0.0.1:8080` (SFTP Go)

## Замечания

1. **Текущая конфигурация портов SFTP Go**: все методы используют порт 8080
   - Можно изменить в `rm_manager_get_origin_port()` для per-method портов

2. **Placeholder по-прежнему находится** в `/var/www/cdn-placeholder`
   - Может быть замещён SFTP Go на любом методе

3. **Переменные сохраняются** в состояние и используются при:
   - Генерации инструкций для CDN-провайдера
   - Конфигурации nginx/Caddy
   - Настройке Remnawave

4. **Совместимость**: все существующие методы (VK, Yandex, Beeline, Timeweb, Selectel, TurboFlare) поддерживают оба варианта origin

## Тестирование

Для проверки работы:
```bash
# Запуск интерактивного режима
./install.sh --manager

# Выбрать метод (например, 4 для Timeweb)
# Выбрать origin (1 для placeholder или 2 для SFTP Go)
# Вводить домены согласно запросам
```
