# АСС — один контейнер с mlog serve (этап 0: только /health).
# Бинарь Metalogos закреплён по версии и SHA256 (тот же релиз, что в tega-platform
# и FOSVED-office-v2). mlog требует glibc >= 2.39 и libssl3 -> Ubuntu 24.04.
FROM ubuntu:24.04
ARG MLOG_VERSION=v0.38.1
ARG MLOG_SHA256=9d1b2f8aa16b81ba146609136697389de06ed3bc447c7c6c19d2f0c66976b7ad

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libssl3 python3 \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /usr/local/bin/mlog \
    "https://github.com/ShkodnikAI/Metalogos-/releases/download/${MLOG_VERSION}/mlog-linux-x86_64" \
 && echo "${MLOG_SHA256}  /usr/local/bin/mlog" | sha256sum -c - \
 && chmod +x /usr/local/bin/mlog

RUN useradd --system --create-home --home-dir /app acc
WORKDIR /app
COPY app.mlog /app/app.mlog
COPY scripts/docker-audit.sh /app/scripts/docker-audit.sh
# АСС-1.3: импорты модулей (core/store, core/ledger, modules/duty/*)
COPY core /app/core
COPY modules /app/modules
# АСС-1.4 (наряд #7, A.1+A.2): скрипты суточных проверок сроков
# (checks/) — их вызывает exec из modules/deadlines/run.mlog;
# python3 выше — интерпретатор скриптов (только stdlib, без пипа).
COPY checks /app/checks
# АСС-1.11 (наряд #39, A.1): конфигурация копируется в /app/seed/, а не в
# /app/data/. Постоянный диск Render смонтирован в /app/data и закрывает
# всё, что образ положил в этот каталог, — паспорта, реестры и статика
# из образа на сервисе исчезали (0 сайтов, пустая статика Mini App).
# На каждом старте scripts/seed-data.sh раскладывает конфигурацию из
# seed/ в data/ с перезаписью (источник истины — репозиторий, изменения
# паспортов идут через PR). Во время работы seed/ только читается.
COPY sites /app/seed/sites
COPY registry /app/seed/registry
# АСС-2.2 (наряд #15, A.2): статика Mini App — источник истины
# modules/miniapp/static/ в репо, доставка через seed (АСС-1.11).
COPY modules/miniapp/static /app/seed/miniapp-static
COPY scripts/seed-data.sh /app/scripts/seed-data.sh
# АСС-1.11 (наряд #39, блок D, D.1): стартовый скрипт контейнера —
# сид → serve → ожидание /health → регистрация расписаний
# (/internal/{duty,deadlines,secretary}/bootstrap) → wait serve.
COPY scripts/start.sh /app/scripts/start.sh
RUN chmod +x /app/scripts/seed-data.sh /app/scripts/start.sh \
 && mkdir -p /app/data && touch /app/data/.keep \
 && chown -R acc:acc /app/data /app/seed /app/scripts/seed-data.sh /app/scripts/start.sh

USER acc
EXPOSE 10000
# АСС-1.4 (наряд #7, A.2): exec открыт нарядом для суточных проверок
# сроков сертификата и домена (единственный exec в репо — гард CI
# scripts/check_exec.sh: exec_argv разрешён только в
# modules/deadlines/run.mlog; аргументы — фиксированный путь скрипта из
# карты и валидированный+сверенный с паспортом домен через
# redact(…, "all"); UNTRUSTED_EXEC_DECISION). В run-режиме (полигоны CI)
# действует METALOGOS_ALLOW_EXEC, в маршрутах serve — отдельный
# METALOGOS_SERVE_ALLOW_EXEC (проба B.7).
ENV METALOGOS_ALLOW_EXEC=1 METALOGOS_SERVE_ALLOW_EXEC=1
# АСС-1.7 (наряд #24, A.1) → АСС-1.9 (наряд #33): движок serve —
# interpreter, до релиза Metalogos с исправлением Metalogos-#1430.
# #1336 (each внутри if) закрыт в 0.33.x; на движке по умолчанию (VM)
# расхождение другого класса (проверено на этом пине): перехват ошибки
# вызова паттерна через try сбрасывает локалы фрейма в Unit —
# (now() - t0) в DutyCheckPage/DutyRecordPage/DutyRecordHealth
# (modules/duty/check.mlog) падает [TYPE_MISMATCH] Float Sub Unit,
# Дежурный молчит при сбое сайта. Решение и условие возврата на VM —
# docs/adr/0003-serve-backend-interpreter.md.
ENV METALOGOS_SERVE_BACKEND=interpreter
# Проверка образа на сборке: синтаксис и аудит безопасности без ошибок.
# Единственный задокументированный допуск — WARN csrf для /tg
# (см. scripts/docker-audit.sh и комментарий middleware в app.mlog).
RUN /app/scripts/docker-audit.sh
# АСС-1.6 A.3a: смонтированный диск закрывает /app/data — .keep создаём
# при старте контейнера, иначе /health → 503 degraded.
# АСС-1.11 (наряд #39, A.3): перед serve — сид конфигурации из /app/seed
# в /app/data (паспорта, реестры, статика; состояние не трогаем).
# АСС-1.11 (наряд #39, блок D, D.1): старт — scripts/start.sh: тот же
# порядок (touch .keep → сид → serve) плюс ожидание /health и регистрация
# расписаний через /internal/{duty,deadlines,secretary}/bootstrap — до
# блока D на проде их никто не вызывал, Healthchecks «ACC Дежурный» не
# получал ни одного пинга (Last Ping: Never). Токен ACC_INTERNAL_TOKEN
# не печатается (URL и тело подавлены в start.sh).
CMD ["/bin/sh", "/app/scripts/start.sh"]