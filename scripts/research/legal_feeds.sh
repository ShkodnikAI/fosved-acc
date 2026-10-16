#!/usr/bin/env bash
# C.2 (наряд АСС-0): есть ли машиночитаемые ленты у pravo.by и tnpa.by.
# Только чтение публичных страниц: robots.txt, главная, ссылки на RSS/Atom.
# Ничего не скачивает массово, по одному запросу на адрес.
set -u
UA="fosved-acc-research/0 (+https://github.com/ShkodnikAI/fosved-acc)"
for host in pravo.by tnpa.by; do
  echo "## $host"
  code=$(curl -s -o /tmp/robots.txt -w '%{http_code}' -A "$UA" -m 20 "https://$host/robots.txt")
  echo "- robots.txt: HTTP $code"
  [ "$code" = 200 ] && grep -iE '^(user-agent|disallow|allow|crawl-delay|sitemap)' /tmp/robots.txt | head -20 | sed 's/^/    /'
  code=$(curl -sL -o /tmp/home.html -w '%{http_code}' -A "$UA" -m 20 "https://$host/")
  echo "- главная: HTTP $code"
  if [ "$code" = 200 ]; then
    echo "- ссылки RSS/Atom в разметке:"
    grep -oiE '<link[^>]+(rss|atom)[^>]*>' /tmp/home.html | head -10 | sed 's/^/    /'
    grep -oiE 'href="[^"]*(rss|feed|subscri|podpis)[^"]*"' /tmp/home.html | sort -u | head -15 | sed 's/^/    /'
  fi
  for path in /rss /rss/ /feed /rss.xml; do
    r=$(curl -s -o /tmp/feed -w '%{http_code} %{content_type}' -A "$UA" -m 20 "https://$host$path")
    echo "- $path: $r"
  done
done
