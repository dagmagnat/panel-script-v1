# Changelog

## 1.2.0

- Каскад стал отдельным режимом: `--cascade`.
- При первой установке сохраняется выбор каскада `да/нет`; если выбрать `нет`, его можно включить позже без переустановки базового CDN.
- В меню уже установленной Remnawave добавлен отдельный пункт каскада.
- Remnawave cascade wizard выбирает две разные ноды: RU relay и foreign exit.
- Exit: добавляет/reuse `BRIDGE_IN` TCP/8888 в активный Config Profile и Active Inbounds, не удаляя старые inbound.
- Relay: создаёт отдельный cascade Config Profile с CDN XHTTP inbound `127.0.0.1:7443`, `VLESS_EXIT` на exit:8888 и routing RU-direct / остальное через exit.
- Создаёт/reuse `PSV1-CASCADE`, bridge-user с явным VLESS UUID и cascade Host.
- Замена активного Profile relay всегда требует отдельного подтверждения; сохраняются JSON-снимки до изменения.
- Provider-side DNS/origin, Caddy на relay и firewall/SG выводятся отдельными `[ВРУЧНУЮ]` инструкциями.
- Добавлены `RELAY-STEPS.txt`, `EXIT-STEPS.txt`, `VERIFY.txt`, `MANUAL-ACTIONS.txt` для каскада.
- Для 3x-ui `--cascade` пока генерирует безопасный чек-лист; автоматическая правка SQLite отложена до живой проверки.

## 1.1.9

- Цветные блоки подготовки/автоматики/ручных действий/проверок.
- Опциональный Cloudflare.
- Xray JSON subscription template и External Squad для Remnawave.
