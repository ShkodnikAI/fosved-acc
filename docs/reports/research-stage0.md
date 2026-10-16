# Исследование этапа 0 (наряд АСС-0, блок C)

Дата: 16.10.2026. Каждый вывод — со ссылкой на первоисточник; непроверенное помечено «не проверено».

## C.1 — права API-ключа Render (ТЗ §17 п. 2)

**Вывод: ключ API Render даёт доступ ко всему аккаунту, ограничить его одним сервисом нельзя. Держать такой ключ в АСС нельзя; деплой — только через мерж в GitHub и Deploy Hook конкретного сервиса.**

- Документация API Render: «An API key provides access to *all* workspaces you belong to.» Средств ограничить ключ сервисом или ресурсом страница не описывает. — [Render API: Authentication](https://api-docs.render.com/reference/authentication)
- Запрос пользователей на ключи с областью в одно рабочее пространство (28.04.2025) подтверждает: ключи «not per-workspace or per-org, and has access to all workspaces». Статуса «сделано» нет. — [Render feedback: API token scoped per workspace](https://feedback.render.com/features/p/api-token-scoped-per-workspace-for-soc-2-compliance)
- Deploy Hook — адрес одного сервиса, который только запускает деплой. Параметр `ref=<SHA>` деплоит конкретный коммит: «https://api.render.com/deploy/srv-XXYYZZ?key=AABBCC&ref=baaa339…». Деплой по хуку с `ref` выключает автодеплой сервиса. — [Render: Deploying a specific commit](https://render.com/docs/deploys)

Следствия:
- ТЗ §4 «деплой через мерж и автодеплой» — правильно; ключ API Render в АСС не храним. Для проверок здоровья и логов (Дежурный) нужен другой путь — публичный `/health` сайта и, если нужно, логи через владельца. Решение по логам — в наряд этапа 1.
- Для FOSVED-office-v2 #524 (A.2) параметр `ref` подтверждён документацией.

## C.2 — машиночитаемые ленты pravo.by и tnpa.by (ТЗ §17 п. 4)

**Статус: не проверено в этой сессии.** Запросы к pravo.by и tnpa.by из среды исполнителя требуют разрешения владельца, которое не было получено вовремя. Проверка перенесена в CI: джоба `research` (скрипт `scripts/research/legal_feeds.sh`) читает robots.txt, главные страницы и стандартные адреса лент, результат — в аннотациях прогона. Итог прогона — ниже, в «Результатах CI».

Известно из ТЗ §9.2 (проверено владельцем раньше): ТНПА публикуются на pravo.by, tnpa.by и сайтах органов; у pravo.by есть RSS новостей портала и «Подписки», про ленту изменений конкретного документа страница не говорит. — [pravo.by: Доступ к ТНПА](https://pravo.by/pravovaya-informatsiya/normativnye-dokumenty/tekhnicheskie-normativnye-pravovye-akty/dostup-k-tnpa/)

## C.3 — срок регистрации домена автоматически (ТЗ §17 п. 16)

**Статус: метод готов, проверка — в CI.** Скрипт `scripts/research/domain_expiry.py` берёт RDAP-сервер зоны из IANA bootstrap (`https://data.iana.org/rdap/dns.json`); если у зоны RDAP нет — WHOIS-сервер зоны из `whois.iana.org`. Печатает только регистратора, даты и статусы; контакты и владельца не выводит. Из среды исполнителя RDAP недоступен (прокси отвечает 403), поэтому прогон — в CI.

- `.plus` — gTLD (делегирование: [IANA .PLUS](https://www.iana.org/domains/root/db/plus.html)); у gTLD RDAP обязателен по договорам ICANN — ожидание: срок читается автоматически (не проверено до прогона CI).
- `.by` — ccTLD; обязанности поддерживать RDAP нет — ожидание: WHOIS или ручное поле паспорта (не проверено до прогона CI).

## C.4 — кто заметит, что упал сам АСС (ТЗ §17 п. 12)

Не менее двух вариантов. Цены — по публичным страницам тарифов на дату проверки; перед выбором сверить.

1. **Внешний пинг `/health` АСС** (UptimeRobot, Better Stack и аналоги: бесплатные тарифы с интервалом 1–5 мин). Ловит: сервис недоступен или отвечает 503 (`degraded`). Не ловит: сервис жив, но расписание встало. Цена: 0 на бесплатном тарифе. Обзоры: [Better Stack: UptimeRobot alternatives 2026](https://betterstack.com/community/comparisons/uptime-robot-alternatives), [Uptime monitoring for indie hackers 2026](https://dev.to/velprove/uptime-monitoring-for-indie-hackers-the-2026-free-stack-3f4i).
2. **«Мёртвая рука» (heartbeat)**: АСС после каждого цикла расписания сам дёргает внешний адрес (Healthchecks.io и аналоги); нет отметки в срок — письмо или Telegram владельцу. Ловит именно «жив, но не работает» — тот класс, что в FOSVED-office-v2 #520 (расписания не зарегистрировались, сервис зелёный). Цена: 0 на бесплатном тарифе. Обзор: [Healthchecks.io alternatives](https://hyperping.com/blog/healthchecks-io-alternatives).
3. **Перекрёстная проверка из Fosved Office** — ночной цикл Admin офиса опрашивает `/health` АСС. Бесплатно, но завязывает АСС на офис, который сам падал (#505, #520); только как третий слой.

Рекомендация: 1 + 2 вместе — это дёшево и закрывает оба класса отказа. Подключение — в наряде этапа 1 (нужен адрес АСС и почта или Telegram владельца для оповещений).

## Результаты CI

_Заполняется по аннотациям джобы `research` на коммите сдачи._
