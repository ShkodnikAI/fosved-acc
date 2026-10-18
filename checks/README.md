# checks/

Скрипты суточных проверок сроков (наряд АСС-1.4, A.1). Вызываются из
`modules/deadlines/run.mlog` (единственный `exec` в репо — гард
`scripts/check_exec.sh` в CI) и информационно из CI-джобы research (A.5).

Контракт каждого скрипта: один аргумент — домен; на выходе одна строка
JSON `{"domain", "expires": "YYYY-MM-DD"|null, "source": "rdap|whois|tls",
"error": null|"..."}`; код выхода 0 даже при ошибке; таймаут 20 с; только
стандартная библиотека Python 3.12. Персональные данные не выводятся.

| Скрипт | Источник срока |
|---|---|
| `cert_expiry.py` | TLS-сертификат (рукопожатие на 443) |
| `domain_expiry.py` | RDAP по IANA bootstrap, фолбэк WHOIS порт 43 |

Юнит-тесты с моками сети — `tests/checks/`.
