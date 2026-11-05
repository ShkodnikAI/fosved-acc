#!/usr/bin/env node
// Рендер вкладки «Приём» (наряд АСС-2.6, A.1+A.2+A.3): чистые функции
// ACC.* — строка → HTML, node без DOM (как tests/sitesapi/dom_test.js).
// Проверяются: дефолты опросника, пометки «найдено автоматически»,
// блок переменных без значений (A.2), строки результата прогона (A.3),
// отсутствие внешних ресурсов (CSP default-src 'self').
"use strict";
const fs = require("fs");
const vm = require("vm");

const src = fs.readFileSync("modules/miniapp/static/app.js", "utf8");
const sandbox = { console, Date, Math, JSON };
vm.createContext(sandbox);
vm.runInContext(src + "\n;ACC", sandbox);
const ACC = sandbox.ACC;
if (!ACC || !ACC.intakeFormHtml) throw new Error("ACC.intakeFormHtml не определён");

// черновик разведки (как из intake_drafts, АСС-2.5): found_auto — name,
// url, languages, checks.pages, repo.health_url; остальное — null
const draft = {
  slug: null, name: "Пример — главная", url: "https://primer.example",
  languages: ["ru", "en"], timezone: null, people: null,
  repo: { github: "ShkodnikAI/tega", branch: null, deploy: null,
          health_url: "https://primer.example/health", key_envs: null },
  checks: { uptime_every_min: null, daily_at: null,
            pages: [{ path: "/", expect_text: "Пример" }] },
  modules: null, limits: null,
  domain: { registrar: null, registrar_panel_url: null, expires: null,
            expires_source: "auto", cert_expires: null, autorenew: null,
            dns_provider: null, warn_days: null, renewal_owner: null },
  profile: null, participation: null,
  platform: { adapter: null, cdn: null }, models: null, sources: null,
  found_auto: ["name", "languages", "checks.pages", "repo.health_url", "repo.github"]
};

// дефолты наряда (A.1): modules, warn_days [60,30,7], profile,
// participation, uptime_every_min 5; found_auto-поля — из черновика
const p = ACC.passportFromDraft(draft);
function eq(a, b, what) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(what + ": " + JSON.stringify(a)); }
eq(p.modules, ["duty", "deadlines", "secretary"], "дефолт modules");
eq(p.domain.warn_days, [60, 30, 7], "дефолт warn_days");
eq(p.profile, "showcase", "дефолт profile");
eq(p.participation, "pr_with_approval", "дефолт participation");
eq(p.checks.uptime_every_min, 5, "дефолт uptime_every_min");
eq(p.name, "Пример — главная", "found_auto name из черновика");
eq(p.checks.pages, [{ path: "/", expect_text: "Пример" }], "found_auto pages из черновика");
eq(p.people.approver_tg_env, "ACC_OWNER_TG_ID", "дефолт approver_tg_env");

// форма: пометки «найдено автоматически» у found_auto-полей и их нет у остальных
const html = ACC.intakeFormHtml(draft, p);
const foundCount = (html.match(/найдено автоматически/g) || []).length;
if (foundCount !== 5) throw new Error("пометок «найдено автоматически»: " + foundCount + ", ожидалось 5 (name, languages, repo.github, repo.health_url, checks.pages)");
if (!/data-path="slug"/.test(html)) throw new Error("нет поля slug");
if (!/data-path="repo.key_envs"/.test(html)) throw new Error("нет поля repo.key_envs");
if (!/data-path="checks.pages"/.test(html)) throw new Error("нет поля pages");
if (!/data-err-for="slug"/.test(html)) throw new Error("нет места ошибки у поля slug");
if (!/id="intake-trial"/.test(html)) throw new Error("нет кнопки «Проверить»");
if (!/id="intake-accept"/.test(html)) throw new Error("нет кнопки «Принять»");
if (!/id="intake-with-notes"/.test(html)) throw new Error("нет отметки «принять с замечаниями»");
if (!/intake-accept" disabled/.test(html)) throw new Error("«Принять» должна быть выключена до зелёного прогона (A.3)");

// блок переменных (A.2): имена без значений, назначение/права, Render
const envHtml = ACC.envBlock({
  repo: { key_envs: ["SITE_PRIMER_GITHUB_TOKEN"] },
  people: { approver_tg_env: "ACC_OWNER_TG_ID", editor_tg_env: null, expert_tg_env: null }
});
if (!/<code>SITE_PRIMER_GITHUB_TOKEN<\/code>/.test(envHtml)) throw new Error("имя переменной сайта не показано");
if (!/Contents: Read and write/.test(envHtml)) throw new Error("нет минимальных прав GitHub-токена");
if (!/<code>ACC_OWNER_TG_ID<\/code>/.test(envHtml)) throw new Error("*_tg_env не показан");
if (!/Environment/.test(envHtml)) throw new Error("нет указателя на Environment хостинга");
if (/https?:\/\//.test(envHtml)) throw new Error("в блоке переменных нет внешних URL (гард АСС-2.2)");
if (/value=/.test(envHtml)) throw new Error("в блоке переменных не должно быть значений");
if (ACC.envHint("SITE_X_TOKEN") === ACC.envHint("SITE_X_CUSTOM")) throw new Error("подсказки не различаются по имени");

// результат прогона (A.3): ok/не ok, время, текст
const trial = ACC.trialBlock({
  green: false,
  pages: [{ path: "/", verdict: "ok", ms: 12.4, text_ok: true },
          { path: "/x", verdict: "no_text", ms: 9.0, text_ok: false }],
  health: { verdict: "ok", ms: 5.0 },
  deadlines: { domain: { expires: "2027-01-01", days: 400, source: "fresh" }, cert: null },
  notes: []
});
if (!/trial-green/.test(trial) === false) throw new Error("нет бейджа прогона");
if (!/class="dl-dot ok"/.test(trial)) throw new Error("нет зелёной строки страницы");
if (!/class="dl-dot err"/.test(trial)) throw new Error("нет красной строки страницы");
if (!/текст не найден/.test(trial)) throw new Error("нет расшифровки no_text");
if (!/12 мс/.test(trial)) throw new Error("нет времени страницы");
if (!/Прогон красный/.test(trial)) throw new Error("нет вердикта красного прогона");

// список черновиков и карточка с PR
const listHtml = ACC.renderIntake([{ url: "https://primer.example", updated_ts: 1700000000, accept: { status: "pr_open", pr_url: "https://github.com/ShkodnikAI/fosved-acc/pull/42" } }]);
if (!/intake-open/.test(listHtml)) throw new Error("нет кнопки открытия опросника");
if (!/pull\/42/.test(listHtml)) throw new Error("нет ссылки PR в карточке");
const emptyHtml = ACC.renderIntake([]);
if (!/Черновиков нет/.test(emptyHtml)) throw new Error("нет пустого состояния списка");

// без внешних ресурсов (CSP default-src 'self')
const all = html + envHtml + trial + listHtml;
if (/<script[^>]+src="/.test(all)) throw new Error("внешний script");
if (/src="https?:\/\//.test(all)) throw new Error("внешний ресурс по src");
if (/href="https?:\/\/(?!dashboard\.render\.com|github\.com)/.test(all)) throw new Error("внешняя ссылка вне Render/GitHub");

// экранирование недоверенных данных (url черновика из БД/сети)
const evil = { url: 'https://x.example"><script>alert(1)</script>', found_auto: [] };
const evilHtml = ACC.intakeCard(evil);
if (/script>/.test(evilHtml.replace(/&lt;script&gt;/g, ""))) throw new Error("xss в intakeCard");
if (!/&lt;script&gt;/.test(evilHtml)) throw new Error("url не экранирован");

console.log("DOM INTAKE OK");
