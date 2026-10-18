# АСС — один контейнер с mlog serve (этап 0: только /health).
# Бинарь Metalogos закреплён по версии и SHA256 (тот же релиз, что в tega-platform
# и FOSVED-office-v2). mlog требует glibc >= 2.39 и libssl3 -> Ubuntu 24.04.
FROM ubuntu:24.04
ARG MLOG_VERSION=v0.32.0
ARG MLOG_SHA256=dd8164b747aa99cb953d3f7a29e084ba38d432df376aa2f05cfd2187e2bc59a2

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
# Зеркало паспортов и реестра В data/: песочница serve №455 разрешает
# файловые чтения только внутри data/; источник истины — sites/ в репо
# (проверяется CI), зеркало обновляется деплоем.
COPY sites /app/data/sites
COPY registry /app/data/registry
RUN mkdir -p /app/data && touch /app/data/.keep && chown -R acc:acc /app/data

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
# Проверка образа на сборке: синтаксис и аудит безопасности без ошибок.
# Единственный задокументированный допуск — WARN csrf для /tg
# (см. scripts/docker-audit.sh и комментарий middleware в app.mlog).
RUN /app/scripts/docker-audit.sh
# АСС-1.6 A.3a: смонтированный диск закрывает /app/data — .keep и
# data/sites создаём при старте контейнера, иначе /health → 503 degraded.
CMD ["sh", "-c", "touch /app/data/.keep && mkdir -p /app/data/sites && exec mlog serve app.mlog"]
