# panel-script-v1 1.2.9

Исправлен ложный post-check по фактическому ответу живой Remnawave 3.3.0:

```json
{
  "id": 2,
  "uuid": null,
  "username": "bridge_995cb9",
  "status": "ACTIVE",
  "activeInternalSquads": [{"name": "PSV1-CASCADE"}]
}
```

Поскольку пользователь успешно прочитан endpoint’ом by-username, для каскада
теперь проверяются VLESS UUID и фактическое членство в squad. Поле user UUID в
3.3.0 не требуется. Также исправлена лишняя `}` в диагностическом снимке.

Все 17 сценарных тестов проходят.
