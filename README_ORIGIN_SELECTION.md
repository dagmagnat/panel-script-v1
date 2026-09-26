# Выбор типа Origin для методов CDN — Итоговое резюме

## 📋 Что было реализовано

Добавлена функциональность выбора типа origin для каждого из 6 методов CDN в panel-script-v1:

```
┌─────────────────────────────────────────┐
│ Выбор метода CDN (1-6)                  │
└─────────┬───────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────┐
│ Выбор типа origin:                      │
│  1 — Заглушка (Placeholder)             │
│  2 — SFTP Go (Web-интерфейс)            │
└─────────┬───────────────────────────────┘
          │
      ┌───┴────┬─────────────┐
      │        │             │
      ▼        ▼             ▼
  ┌───────┐ ┌──────┐   ┌──────────┐
  │:80    │ │:443  │   │:8080     │
  │Timeweb│ │Yandex│   │SFTP Go   │
  └───────┘ └──────┘   │(все)     │
                       └──────────┘
```

## ✨ Добавленные функции

### 1. `method_title()` — красивые названия методов
```bash
method_title "vk" → "VK Cloud"
method_title "yandex" → "Yandex Cloud"
# и т.д. для всех 6 методов
```

### 2. `rm_manager_choose_origin_type()` — интерактивное меню выбора
```
Тип origin (что будет доступно по CDN):
  1 — Заглушка (placeholder website)
  2 — SFTP Go (web-интерфейс хранилища файлов)
  0 — Назад
```

### 3. `rm_manager_get_origin_port()` — определение порта
- **Placeholder**: 80 (VK, Timeweb), 443 (остальные)
- **SFTP Go**: 8080 (все методы)

### 4. `rm_manager_get_origin_scheme()` — схема подключения
- Всегда возвращает `http` (можно расширить на `https`)

### 5. Обновлена `rm_manager_collect_domains()`
Добавлены 3 шага:
1. Выбор типа origin (placeholder/sftpgo)
2. Сбор доменов (как раньше)
3. Сводка конфигурации

### 6. Обновлена `rm_manager_provider_steps()`
Инструкции теперь включают info о типе origin

## 🎯 Использование

### Для конечного пользователя

```bash
# Запустить менеджер
./install.sh --manager

# Выбрать метод CDN (1-6)
Какой CDN добавить в существующую панель?
  4 — Timeweb

# Выбрать тип origin (1-2)
Тип origin (что будет доступно по CDN):
  1 — Заглушка (placeholder website)

# Ввести домены
Origin-домен...
CDN-домен...
```

### Результат

```bash
# Сохраняются переменные:
ORIGIN_TYPE="placeholder"      # или "sftpgo"
ORIGIN_PORT="80"               # или "443", "8080"
ORIGIN_SCHEME="http"
ORIGIN_DOMAIN="origin.example.net"
CDN_DOMAIN="cdn.example.net"
```

## 📁 Измененные файлы

- **`install.sh`** — добавлены функции и логика выбора
  - Строки 221-231: `method_title()`
  - Строки 793-810: `rm_manager_choose_origin_type()`
  - Строки 812-852: `rm_manager_get_origin_port()` и `rm_manager_get_origin_scheme()`
  - Строки 854-909: обновлена `rm_manager_collect_domains()`
  - Строки 1260+: обновлена `rm_manager_provider_steps()`

## 📚 Документация

- **`CHANGES_SUMMARY.md`** — детальное описание всех изменений
- **`ORIGIN_SELECTION_GUIDE.md`** — руководство пользователя

## 🔧 Поддерживаемые методы CDN

Все 6 методов поддерживают оба типа origin:

| № | Метод | Placeholder | SFTP Go |
|---|-------|-------------|---------|
| 1 | VK Cloud | :80 | :8080 |
| 2 | Yandex Cloud | :443 | :8080 |
| 3 | Beeline / CDNvideo | :443 | :8080 |
| 4 | Timeweb | :80 | :8080 |
| 5 | Selectel | :443 | :8080 |
| 6 | TurboFlare | :443 | :8080 |

## 🚀 Примеры

### Пример 1: Timeweb + Placeholder
```
Method: timeweb
Origin Type: placeholder
Origin Address: 127.0.0.1:80
CDN Domain: cdn.example.com
```

### Пример 2: VK Cloud + SFTP Go
```
Method: vk
Origin Type: sftpgo
Origin Address: 127.0.0.1:8080
Origin Domain: origin.example.net
CDN Domain: cdn.example.net
```

## 📝 Примечания

### Текущая конфигурация
- SFTP Go использует единый порт **8080** для всех методов
- Можно изменить портовую схему в `rm_manager_get_origin_port()`

### Совместимость
- Все методы поддерживают оба варианта origin
- Placeholder всегда в `/var/www/cdn-placeholder`
- Переменные сохраняются и используются при конфигурации nginx/Caddy

### Расширяемость
- Легко добавить новые типы origin (например, nginx, Apache, Apache, etc.)
- Функции модульные и легко тестируются
- Поддержка HTTPS можно добавить в `rm_manager_get_origin_scheme()`

## 🧪 Тестирование

Для проверки синтаксиса bash:
```bash
bash -n install.sh
```

Для интерактивного тестирования:
```bash
./install.sh --manager
# Выбрать метод → выбрать origin → ввести домены
```

## ✅ Результат

После реализации пользователь может:

✓ Выбирать тип origin для каждого метода CDN  
✓ Использовать placeholder для тестирования  
✓ Использовать SFTP Go для хранения файлов  
✓ Видеть в инструкциях информацию о выбранном origin  
✓ Легко переключаться между типами origin  

## 📞 Поддержка

Для каждого выбора доступны инструкции от CDN-провайдера, которые включают информацию о типе origin и адресе, на который нужно проксировать трафик.

---

**Версия**: panel-script-v1 1.4.5+  
**Дата**: 2026-09-26  
**Статус**: ✅ Готово к использованию
