# АСС — один контейнер с mlog serve (этап 0: только /health).
# Бинарь Metalogos закреплён по версии и SHA256 (тот же релиз, что в tega-platform
# и FOSVED-office-v2). mlog требует glibc >= 2.39 и libssl3 -> Ubuntu 24.04.
FROM ubuntu:24.04
ARG MLOG_VERSION=v0.32.0
ARG MLOG_SHA256=dd8164b747aa99cb953d3f7a29e084ba38d432df376aa2f05cfd2187e2bc59a2

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /usr/local/bin/mlog \
    "https://github.com/ShkodnikAI/Metalogos-/releases/download/${MLOG_VERSION}/mlog-linux-x86_64" \
 && echo "${MLOG_SHA256}  /usr/local/bin/mlog" | sha256sum -c - \
 && chmod +x /usr/local/bin/mlog

RUN useradd --system --create-home --home-dir /app acc
WORKDIR /app
COPY app.mlog /app/app.mlog
RUN mkdir -p /app/data && touch /app/data/.keep && chown -R acc:acc /app/data

USER acc
EXPOSE 10000
# Проверка образа на сборке: синтаксис и аудит безопасности без ошибок.
RUN mlog check app.mlog && mlog audit app.mlog
CMD ["mlog", "serve", "app.mlog"]
