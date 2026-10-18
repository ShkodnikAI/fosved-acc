#!/usr/bin/env node
// Тест 5 наряда АСС-2.3 (A.3): снимок DOM-разметки карточек вкладки
// «Сайты». Рендер-функции ACC.* — чистые (строка → HTML), app.js в node
// пропускает DOM-инициализацию (typeof document === "undefined"), поэтому
// снапшот снимается с реального прод-рендера без jsdom/Playwright.
//
// Фикстуры — те же данные, что /api/sites отдаёт для двух сайтов
// tests/sitesapi/run.sh (зелёный и с открытым инцидентом).
"use strict";
const fs = require("fs");
const vm = require("vm");

const src = fs.readFileSync("modules/miniapp/static/app.js", "utf8");
const sandbox = { console, Date, Math, JSON };
vm.createContext(sandbox);
vm.runInContext(src + "\n;ACC", sandbox);
const ACC = sandbox.ACC;
if (!ACC || !ACC.siteCard) throw new Error("ACC.siteCard не определён");

const now = Math.floor(Date.now() / 1000);
// фикстура 2 — сайт с открытым инцидентом (rsite из юнитов)
const red = {
  slug: "rsite", name: "Красный тест", url: "https://red.example",
  color: "red", paused: true,
  last_check: { ts: String(now - 120), ok: false, ms: 8.0 },
  open_incidents: [{ kind: "down", since: now - 120 }],
  deadlines: { domain: { expires: "2026-11-01", days: 13, source: "rdap" },
               cert: { expires: null, days: null, source: null } }
};
const htmlRed = ACC.siteCard(red);
if (!/class="card site-card red"/.test(htmlRed)) throw new Error("нет карточки class=red");
if (!/>down с /.test(htmlRed)) throw new Error("нет текста инцидента");
if (!/>на паузе</.test(htmlRed)) throw new Error("нет метки паузы");
if (!/нет данных/.test(htmlRed)) throw new Error("срок без данных не «нет данных»");

// фикстура 1 — зелёный (gsite из юнитов; срок домена 5 дней)
const green = {
  slug: "gsite", name: "Зелёный тест", url: "https://green.example",
  color: "green", paused: false,
  last_check: { ts: String(now - 60), ok: true, ms: 12.0 },
  open_incidents: [],
  deadlines: { domain: { expires: "2026-10-24", days: 5, source: "rdap" },
               cert: { expires: "2026-12-20", days: 62, source: "rdap" } }
};
const htmlGreen = ACC.siteCard(green);
if (!/class="card site-card green"/.test(htmlGreen)) throw new Error("нет карточки class=green");
if (!/домен: 5 дн/.test(htmlGreen)) throw new Error("нет срока 5 дней");
if (/class="incident"/.test(htmlGreen)) throw new Error("инциденты не должны рендериться");

// пороги сроков наряда (A.2): ≤7 — красный, ≤30 — жёлтый, неизвестен — «нет данных»
if (!/dl-dot red/.test(ACC.deadlineItem("домен", { days: 5, expires: "x", source: "rdap" })))
  throw new Error("порог ≤7 не красный");
if (!/dl-dot yellow/.test(ACC.deadlineItem("домен", { days: 25, expires: "x", source: "rdap" })))
  throw new Error("порог ≤30 не жёлтый");
if (!/dl-dot ok/.test(ACC.deadlineItem("домен", { days: 61, expires: "x", source: "rdap" })))
  throw new Error("срок >30 должен быть обычным");
if (!/нет данных/.test(ACC.deadlineItem("домен", null))) throw new Error("null — не «нет данных»");

// пустой список — «Сайтов на обслуживании нет» + кнопка обновления
const empty = ACC.renderSites([]);
if (!/Сайтов на обслуживании нет/.test(empty)) throw new Error("нет пустого состояния");
if (!/id="refresh"/.test(empty)) throw new Error("нет кнопки обновления");

console.log("DOM SNAPSHOT OK");
