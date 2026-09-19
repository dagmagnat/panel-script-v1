# panel-script-v1 1.4.0

CDN-нода теперь может показывать не только статическую заглушку, но и настоящий
SFTPGo из проекта `dagmagnat/SFTPGo-manager`.

```bash
/root/panel-script-v1.sh --frontend
/root/panel-script-v1.sh --frontend sftpgo cloud.example.com
/root/panel-script-v1.sh --frontend placeholder
```

Интеграционный режим не запускает Caddy из исходного SFTPGo-manager. Контейнер
`psv1-sftpgo` слушает только `127.0.0.1:18080`, а существующий nginx продолжает
обслуживать `80/443`: XHTTP path идёт в Xray, остальные URL — в SFTPGo.

nginx меняется атомарно с резервной копией, проверкой синтаксиса, graceful
reload и контролем неизменности ответа XHTTP. Возврат к заглушке не удаляет
файлы или базу пользователей SFTPGo.
