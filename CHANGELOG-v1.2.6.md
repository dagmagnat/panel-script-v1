# panel-script-v1 1.2.6

Главное исправление: каскад теперь подтверждается фактическим состоянием Remnawave, а не формой тела успешного API-ответа.

- Команды установки и ручного обновления теперь удаляют CRLF после загрузки;
- встроенный `--update` выполняет такую же нормализацию до проверки новой версии;

- bridge-user после создания/обновления перечитывается через `GET /api/users/by-username/...`;
- при необходимости членство добавляется через Internal Squad bulk-action;
- squad перечитывается detail endpoint и не теряет старые inbound;
- Node assignment/Active Inbounds проверяются read-after-write;
- перед итогом проверяются relay, все exit, squad, users UUID и routing;
- TurboFlare `IP:443` на shared panel+relay больше не блокируется недостижимым guard;
- nginx bridge применяется до API-изменений и полностью откатывается при ошибке;
- полный `install.sh` уже обновлён до v1.2.6.

Проверка:

```bash
bash -n install.sh
bash -n cascade-nginx-fix.sh
bash tests/cascade-tests.sh
```
