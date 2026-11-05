// АСС Mini App — каркас + вкладка «Сайты» (наряды АСС-2.2, АСС-2.3).
// Без внешних ресурсов. Токен: из location.hash (#s=…), hash стирается
// сразу (history.replaceState), уходит заголовком X-ACC-Session на все
// /api/*. Не хранится в localStorage и cookie — живёт в памяти страницы.
//
// Рендер-функции (ACC.*) — чистые: строка → строка HTML, тестируются
// в node без DOM (tests/sitesapi/dom_test.js). Инициализация — при
// наличии document (в проде; в node-тесте typeof document === "undefined").

var ACC = {
  esc: function (s) {
    // экранирование текста в HTML (данные сайтов — недоверенные)
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  },

  // срок домена/сертификата: строка класса и текста по порогам наряда
  // (≤7 — красный, ≤30 — жёлтый, иначе зелёный/ok; null — «нет данных»)
  deadlineItem: function (title, d) {
    if (!d || d.days === null || d.days === undefined) {
      return '<div class="dl"><span class="dl-dot gray"></span>' + this.esc(title) +
        ': <span class="muted">нет данных</span></div>';
    }
    var cls = "ok";
    if (d.days <= 7) { cls = "red"; } else if (d.days <= 30) { cls = "yellow"; }
    return '<div class="dl"><span class="dl-dot ' + cls + '"></span>' + this.esc(title) +
      ': ' + this.esc(d.days) + ' дн</div>';
  },

  incidentLine: function (inc) {
    var kind = inc && inc.kind ? inc.kind : "?";
    var since = inc && inc.since ? new Date(inc.since * 1000).toISOString() : "";
    return '<div class="incident">' + this.esc(kind) +
      (since ? " с " + this.esc(since) : "") + "</div>";
  },

  // карточка сайта (АСС-2.3 A.2): метка цвета, название/адрес,
  // «проверено N мин назад», инциденты, сроки
  siteCard: function (site) {
    var color = site && site.color ? site.color : "gray";
    var last = "";
    if (site && site.last_check && site.last_check.ts) {
      var mins = Math.max(0, Math.round((Date.now() / 1000 - Number(site.last_check.ts)) / 60));
      last = '<div class="checked ' + (site.last_check.ok ? "" : "err") + '">проверено ' +
        mins + ' мин назад</div>';
    } else {
      last = '<div class="checked muted">проверок ещё не было</div>';
    }
    var incidents = "";
    if (site && site.open_incidents && site.open_incidents.length) {
      var self = this;
      incidents = site.open_incidents.map(function (x) { return self.incidentLine(x); }).join("");
    }
    var dl = site && site.deadlines ? site.deadlines : {};
    return '<div class="card site-card ' + this.esc(color) + '">' +
      '<span class="dot ' + this.esc(color) + '"></span>' +
      '<div class="site-name">' + this.esc(site.name || site.slug || "?") + "</div>" +
      '<div class="site-url">' + this.esc(site.url || "") + "</div>" +
      last + incidents +
      this.deadlineItem("домен", dl.domain) +
      this.deadlineItem("сертификат", dl.cert) +
      (site && site.paused ? '<div class="paused">на паузе</div>' : "") +
      "</div>";
  },

  // ── АСС-2.4: вкладки «Модели» и «Источники» ──
  regEntryCard: function (kind, e) {
    var self = this;
    var fields = "";
    Object.keys(e).forEach(function (k) {
      if (k === "id") { return; }
      fields += '<div class="dl"><span class="muted">' + self.esc(k) + ':</span> ' + self.esc(e[k]) + '</div>';
    });
    var st = e.status === "active" ? "green" : "gray";
    var ops = "";
    if (e.status === "active") {
      ops = '<button class="tab op" data-kind="' + this.esc(kind) + '" data-op="disable" data-id="' + this.esc(e.id) + '">Выключить</button>';
    } else {
      ops = '<button class="tab op" data-kind="' + this.esc(kind) + '" data-op="enable" data-id="' + this.esc(e.id) + '">Включить</button>';
    }
    ops += '<button class="tab op" data-kind="' + this.esc(kind) + '" data-op="delete" data-id="' + this.esc(e.id) + '">Удалить</button>';
    return '<div class="card reg-card">' +
      '<span class="dot ' + st + '"></span>' +
      '<div class="site-name">' + this.esc(e.id) + '</div>' + fields +
      '<div class="dl"><span class="muted">status:</span> ' + this.esc(e.status) + '</div>' +
      '<div class="ops">' + ops + '</div>' +
      '<div class="confirm hidden">Удалить/изменить запись? <button class="tab op-go" data-kind="' + this.esc(kind) + '" data-op="" data-id="' + this.esc(e.id) + '">Подтвердить</button> <button class="tab op-no">Отмена</button></div>' +
      '</div>';
  },

  regAddForm: function (kind) {
    var fields = kind === "sources"
      ? '<input name="id" placeholder="id (a-z0-9-, 2-40)"><input name="domain" placeholder="домен (без схемы/пути)"><input name="kind" placeholder="kind (registry|watchdog|…)"><input name="read_method" placeholder="read_method (http|whois|…)"><input name="frequency" placeholder="frequency (weekly|on-demand|…)">'
      : '<input name="id" placeholder="id (a-z0-9-, 2-40)"><input name="name" placeholder="название"><input name="provider" placeholder="провайдер"><input name="model" placeholder="модель"><input name="key_env" placeholder="key_env — ИМЯ переменной (ABC_DEF)">';
    return '<div class="card reg-add" data-kind="' + this.esc(kind) + '">' +
      '<div class="site-name">Добавить запись</div>' + fields +
      '<input name="terms" placeholder="terms_checked: да/нет" value="да">' +
      '<button class="tab op-add" data-kind="' + this.esc(kind) + '">Отправить PR</button>' +
      '<div class="msg pr-result"></div>' +
      '</div>';
  },

  renderRegistry: function (kind, list) {
    var self = this;
    if (!list || !list.length) {
      return '<div class="empty">Записей нет</div>' + this.regAddForm(kind);
    }
    return list.map(function (e) { return self.regEntryCard(kind, e); }).join("") + this.regAddForm(kind);
  },

  renderSites: function (list) {
    if (!list || !list.length) {
      return '<div class="empty">Сайтов на обслуживании нет</div>' +
        '<button class="tab" id="refresh">Обновить</button>';
    }
    var self = this;
    return list.map(function (s) { return self.siteCard(s); }).join("") +
      '<button class="tab" id="refresh">Обновить</button>';
  },

  // ── АСС-2.6: вкладка «Приём» (опросник, переменные, прогон, «Принять») ──

  // паспорт по умолчанию из черновика (A.1): поля found_auto — из черновика,
  // остальные — дефолты наряда (modules, warn_days, profile, participation,
  // uptime_every_min); чистая функция — тестируется в node
  passportFromDraft: function (draft) {
    var d = draft || {};
    return {
      slug: d.slug || "",
      name: d.name || "",
      url: d.url || "",
      languages: d.languages || [],
      timezone: d.timezone || "",
      people: {
        approver_tg_env: (d.people && d.people.approver_tg_env) || "ACC_OWNER_TG_ID",
        editor_tg_env: (d.people && d.people.editor_tg_env) || null,
        expert_tg_env: (d.people && d.people.expert_tg_env) || null
      },
      repo: {
        github: (d.repo && d.repo.github) || "",
        branch: (d.repo && d.repo.branch) || "main",
        deploy: (d.repo && d.repo.deploy) || "render_hook",
        health_url: (d.repo && d.repo.health_url) || "",
        key_envs: (d.repo && d.repo.key_envs) || []
      },
      checks: {
        uptime_every_min: (d.checks && d.checks.uptime_every_min) || 5,
        daily_at: (d.checks && d.checks.daily_at) || "07:00",
        pages: (d.checks && d.checks.pages) || []
      },
      modules: d.modules || ["duty", "deadlines", "secretary"],
      limits: (d.limits && d.limits.tokens_per_day !== undefined) ? d.limits : { tokens_per_day: 0, deploys_per_day: 0 },
      domain: {
        registrar: (d.domain && d.domain.registrar) || null,
        registrar_panel_url: (d.domain && d.domain.registrar_panel_url) || null,
        expires: (d.domain && d.domain.expires) || null,
        expires_source: (d.domain && d.domain.expires_source) || "auto",
        cert_expires: (d.domain && d.domain.cert_expires) || null,
        autorenew: (d.domain && d.domain.autorenew) || null,
        dns_provider: (d.domain && d.domain.dns_provider) || null,
        warn_days: (d.domain && d.domain.warn_days) || [60, 30, 7],
        renewal_owner: (d.domain && d.domain.renewal_owner) || "owner"
      },
      profile: d.profile || "showcase",
      participation: d.participation || "pr_with_approval",
      platform: {
        adapter: (d.platform && d.platform.adapter) || null,
        cdn: (d.platform && d.platform.cdn) || null
      },
      models: d.models || { policy: "router", allow: [], deny: [], tokens_per_day: 0 },
      sources: d.sources || []
    };
  },

  foundMark: function (draft, path) {
    // «найдено автоматически» у полей из found_auto (A.1)
    var fa = (draft && draft.found_auto) || [];
    if (fa.indexOf(path) !== -1) {
      return '<span class="found-mark">найдено автоматически</span>';
    }
    return "";
  },

  envHint: function (name) {
    // назначение и минимальные права переменной хостинга (A.2); значение
    // нигде не вводится — только имя (правило 8 паспорта)
    var n = String(name || "");
    if (/GITHUB/i.test(n)) {
      return "токен GitHub сайта — Contents: Read and write, Pull requests: Read and write (PR паспорта/реестров сайта)";
    }
    if (/TG|TELEGRAM/i.test(n)) {
      return "Telegram id человека (значение — id, не токен)";
    }
    if (/TOKEN|KEY|SECRET|PASSWORD/i.test(n)) {
      return "ключ сайта — минимальные достаточные права по назначению переменной";
    }
    return "переменная сайта — минимальные достаточные права по назначению";
  },

  envBlock: function (p) {
    // блок «Что внести в хостинг АСС» (A.2): имена без значений,
    // назначение и минимальные права, ссылка на Environment в Render
    var self = this;
    var rows = "";
    var names = (p && p.repo && p.repo.key_envs) || [];
    names.forEach(function (n) {
      rows += '<div class="env-row"><code>' + self.esc(n) + '</code><div class="muted">' + self.esc(self.envHint(n)) + "</div></div>";
    });
    if (p && p.people) {
      ["approver_tg_env", "editor_tg_env", "expert_tg_env"].forEach(function (k) {
        if (p.people[k]) {
          rows += '<div class="env-row"><code>' + self.esc(p.people[k]) + '</code><div class="muted">Telegram id человека (значение — только id)</div></div>';
        }
      });
    }
    if (!rows) {
      rows = '<div class="muted">Переменных сайта паспорт не требует (repo.key_envs пуст)</div>';
    }
    return '<div class="card env-block"><div class="site-name">Что внести в хостинг АСС</div>' + rows +
      // NB: гиперссылки на dashboard.render.com здесь нет — гард АСС-2.2
      // запрещает внешние URL в статике (CSP default-src 'self'); указатель
      // текстом: Render → сервис АСС → Environment
      '<div class="muted">Значения не вводятся здесь — только на странице Environment сервиса АСС у хостинга (Render: ваш сервис → Environment). Значения вносятся по именам из этого списка.</div></div>';
  },

  intakeCard: function (d) {
    var acc = d && d.accept ? d.accept : null;
    var st = "";
    if (acc && acc.status === "pr_open" && acc.pr_url) {
      st = '<div class="dl">PR: <a href="' + this.esc(acc.pr_url) + '">' + this.esc(acc.pr_url) + "</a></div>";
    }
    var date = d && d.updated_ts ? new Date(Number(d.updated_ts) * 1000).toLocaleString() : "";
    return '<div class="card intake-card">' +
      '<div class="site-name">' + this.esc((d && d.url) || "?") + "</div>" +
      '<div class="checked muted">' + this.esc(date) + "</div>" + st +
      '<button class="tab intake-open" data-url="' + this.esc((d && d.url) || "") + '">Заполнить опросник</button>' +
      "</div>";
  },

  renderIntake: function (list) {
    if (!list || !list.length) {
      return '<div class="empty">Черновиков нет — подайте заявку боту: «прими сайт <адрес>»</div>' +
        '<button class="tab" id="intake-refresh">Обновить</button>';
    }
    var self = this;
    return list.map(function (d) { return self.intakeCard(d); }).join("") +
      '<button class="tab" id="intake-refresh">Обновить</button>';
  },

  trialPage: function (p) {
    // строка результата прогона по странице (A.3): статус, время, текст
    var cls = p && p.verdict === "ok" ? "ok" : "err";
    var names = { ok: "ok", down: "недоступна", no_text: "текст не найден", slow: "медленно" };
    var v = p && p.verdict ? (names[p.verdict] || p.verdict) : "?";
    var ms = p && p.ms !== undefined ? String(Math.round(Number(p.ms))) : "?";
    return '<div class="trial-row"><span class="dl-dot ' + cls + '"></span>' + this.esc(p.path || "?") +
      ': <span class="' + cls + '">' + this.esc(v) + "</span> (" + this.esc(ms) + " мс)</div>";
  },

  trialBlock: function (t) {
    // результат пробного прогона целиком (A.3)
    var self = this;
    var badge = t && t.green
      ? '<div class="trial-green">Прогон зелёный — можно принимать</div>'
      : '<div class="trial-red">Прогон красный — принять нельзя (или отметьте «принять с замечаниями»)</div>';
    var rows = "";
    if (t && t.pages) {
      rows += t.pages.map(function (p) { return self.trialPage(p); }).join("");
    }
    if (t && t.health) {
      rows += this.trialPage({ path: "health_url", verdict: t.health.verdict, ms: t.health.ms });
    }
    var dl = t && t.deadlines ? t.deadlines : {};
    rows += this.deadlineItem("домен", dl.domain);
    rows += this.deadlineItem("сертификат", dl.cert);
    if (t && t.notes && t.notes.length) {
      rows += t.notes.map(function (n) { return '<div class="trial-note">' + self.esc(n) + "</div>"; }).join("");
    }
    return '<div class="card trial-result">' + badge + rows + "</div>";
  },

  fieldRow: function (label, path, value, draft, extra) {
    // строка формы: подпись + пометка found_auto + поле + место ошибки
    var v = value === null || value === undefined ? "" : String(value);
    return '<label class="pf-row"><span class="pf-label">' + this.esc(label) + " " + this.foundMark(draft, path) + "</span>" +
      '<input class="pf" data-path="' + this.esc(path) + '" value="' + this.esc(v) + '"' + (extra || "") + ">" +
      '<span class="field-err" data-err-for="' + this.esc(path) + '"></span></label>';
  },

  intakeFormHtml: function (draft, passport) {
    // форма паспорта по полям ADR-0002, группы — шаги 3–6 ТЗ §5 (A.1)
    var self = this;
    var p = passport;
    var draftUrl = (draft && draft.url) || "";
    var pagesText = (p.checks.pages || []).map(function (pg) { return pg.path + " | " + pg.expect_text; }).join("\n");
    function sec(title, inner) {
      return '<details class="pf-sec" open><summary>' + self.esc(title) + "</summary>" + inner + "</details>";
    }
    var common = this.fieldRow("slug", "slug", p.slug, draft) +
      this.fieldRow("название", "name", p.name, draft) +
      this.fieldRow("адрес сайта (https)", "url", p.url, draft) +
      this.fieldRow("языки (через запятую)", "languages", (p.languages || []).join(", "), draft) +
      this.fieldRow("таймзона", "timezone", p.timezone, draft);
    var people = this.fieldRow("согласующий (*_tg_env)", "people.approver_tg_env", p.people.approver_tg_env, draft) +
      this.fieldRow("редактор (*_tg_env)", "people.editor_tg_env", p.people.editor_tg_env, draft) +
      this.fieldRow("эксперт (*_tg_env)", "people.expert_tg_env", p.people.expert_tg_env, draft);
    var repo = this.fieldRow("GitHub (owner/repo)", "repo.github", p.repo.github, draft) +
      this.fieldRow("ветка", "repo.branch", p.repo.branch, draft) +
      this.fieldRow("деплой", "repo.deploy", p.repo.deploy, draft) +
      this.fieldRow("health_url (https)", "repo.health_url", p.repo.health_url, draft) +
      this.fieldRow("переменные сайта (имена, через запятую)", "repo.key_envs", (p.repo.key_envs || []).join(", "), draft);
    var checks = this.fieldRow("период проверки (мин)", "checks.uptime_every_min", p.checks.uptime_every_min, draft) +
      this.fieldRow("суточная проверка (ЧЧ:ММ)", "checks.daily_at", p.checks.daily_at, draft) +
      '<label class="pf-row"><span class="pf-label">страницы (путь | ожидаемый текст) ' + this.foundMark(draft, "checks.pages") + '</span>' +
      '<textarea class="pf pf-pages" data-path="checks.pages">' + this.esc(pagesText) + '</textarea>' +
      '<span class="field-err" data-err-for="checks.pages"></span></label>';
    var mods = this.fieldRow("модули (через запятую)", "modules", (p.modules || []).join(", "), draft) +
      this.fieldRow("лимит токенов/сутки", "limits.tokens_per_day", p.limits.tokens_per_day, draft) +
      this.fieldRow("лимит деплоев/сутки", "limits.deploys_per_day", p.limits.deploys_per_day, draft);
    var domain = this.fieldRow("регистратор", "domain.registrar", p.domain.registrar, draft) +
      this.fieldRow("панель регистратора", "domain.registrar_panel_url", p.domain.registrar_panel_url, draft) +
      this.fieldRow("срок домена (ГГГГ-ММ-ДД)", "domain.expires", p.domain.expires, draft) +
      this.fieldRow("срок сертификата (ГГГГ-ММ-ДД)", "domain.cert_expires", p.domain.cert_expires, draft) +
      this.fieldRow("автопродление (да/нет)", "domain.autorenew", p.domain.autorenew, draft) +
      this.fieldRow("DNS-провайдер", "domain.dns_provider", p.domain.dns_provider, draft) +
      this.fieldRow("пороги дней (по убыванию)", "domain.warn_days", (p.domain.warn_days || []).join(", "), draft) +
      this.fieldRow("ответственный за продление", "domain.renewal_owner", p.domain.renewal_owner, draft);
    var prof = this.fieldRow("профиль (showcase|service|ugc|paid)", "profile", p.profile, draft) +
      this.fieldRow("участие (pr_with_approval|report_only)", "participation", p.participation, draft) +
      this.fieldRow("адаптер платформы (render|home-server)", "platform.adapter", p.platform.adapter, draft) +
      this.fieldRow("CDN", "platform.cdn", p.platform.cdn, draft);
    var models = this.fieldRow("политика моделей", "models.policy", p.models.policy, draft) +
      this.fieldRow("модели — разрешено", "models.allow", (p.models.allow || []).join(", "), draft) +
      this.fieldRow("модели — запрещено", "models.deny", (p.models.deny || []).join(", "), draft) +
      this.fieldRow("токенов/сутки", "models.tokens_per_day", p.models.tokens_per_day, draft) +
      this.fieldRow("источники (id, через запятую)", "sources", (p.sources || []).join(", "), draft);
    return '<div class="card intake-form" data-url="' + this.esc(draftUrl) + '">' +
      '<div class="site-name">Опросник приёма: ' + this.esc(draftUrl) + "</div>" +
      sec("Общее", common) + sec("Люди (только имена переменных *_tg_env)", people) +
      sec("Репозиторий и деплой", repo) + sec("Проверки", checks) +
      sec("Модули и лимиты", mods) + sec("Домен", domain) +
      sec("Профиль и платформа", prof) + sec("Модели и источники", models) +
      this.envBlock(p) +
      '<div class="intake-actions"><button class="tab" id="intake-trial">Проверить</button>' +
      '<label class="with-notes"><input type="checkbox" id="intake-with-notes"> принять с замечаниями</label>' +
      '<button class="tab" id="intake-accept" disabled>Принять на обслуживание</button></div>' +
      '<div class="trial-out"></div>' +
      '<div class="msg intake-msg"></div>' +
      '<button class="tab" id="intake-back">К списку черновиков</button>' +
      "</div>";
  }
};

if (typeof document !== "undefined") {
  (function () {
    var msg = document.getElementById("msg");
    var tabs = document.getElementById("tabs");
    var view = document.getElementById("view");
    var token = "";

    function show(text, isError) {
      msg.textContent = text;
      msg.className = isError ? "msg err" : "msg";
    }

    function api(path, cb) {
      fetch(path, { headers: { "X-ACC-Session": token } })
        .then(function (r) {
          if (r.status === 401) {
            show("Ссылка устарела — напишите боту /app", true);
            return null;
          }
          return r.json().then(function (j) { cb(r.status, j); });
        })
        .catch(function () { show("Сеть недоступна", true); });
    }

    var TITLES = { sites: "Сайты", intake: "Приём", models: "Модели", sources: "Источники" };

    // ── АСС-2.6: сбор паспорта из формы ──
    function setDeep(obj, path, value) {
      var parts = path.split(".");
      var cur = obj;
      for (var i = 0; i < parts.length - 1; i++) {
        if (!cur[parts[i]] || typeof cur[parts[i]] !== "object") {
          cur[parts[i]] = {};
        }
        cur = cur[parts[i]];
      }
      cur[parts[parts.length - 1]] = value;
    }

    function collectPassport(root, draft) {
      // дефолт — из черновика (чистая функция ACC.passportFromDraft),
      // затем поля формы (data-path); пустые значения nullable-полей — null
      var p = ACC.passportFromDraft(draft);
      var lists = { languages: 1, modules: 1, "domain.warn_days": 1, sources: 1, "repo.key_envs": 1, "models.allow": 1, "models.deny": 1 };
      var nums = { "checks.uptime_every_min": 1, "limits.tokens_per_day": 1, "limits.deploys_per_day": 1, "models.tokens_per_day": 1 };
      Array.prototype.forEach.call(root.querySelectorAll(".pf"), function (inp) {
        var path = inp.getAttribute("data-path");
        if (!path) { return; }
        var val = inp.value;
        if (path === "checks.pages") {
          var pages = [];
          val.split("\n").forEach(function (ln) {
            var t = ln.trim();
            if (!t) { return; }
            var sep = t.indexOf("|");
            if (sep === -1) {
              pages.push({ path: t, expect_text: "" });
            } else {
              pages.push({ path: t.slice(0, sep).trim(), expect_text: t.slice(sep + 1).trim() });
            }
          });
          setDeep(p, path, pages);
          return;
        }
        var v = val.trim();
        if (lists[path]) {
          setDeep(p, path, v ? v.split(/[,;]/).map(function (x) { return x.trim(); }).filter(function (x) { return x; }) : []);
          return;
        }
        if (nums[path]) {
          setDeep(p, path, v === "" ? 0 : Number(v) || 0);
          return;
        }
        setDeep(p, path, v === "" ? null : v);
      });
      return p;
    }

    function postIntake(path, payload, cb) {
      fetch(path, {
        method: "POST",
        headers: { "X-ACC-Session": token, "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      }).then(function (r) {
        return r.json().then(function (j) { cb(r.status, j); });
      }).catch(function () { cb(0, { error: "сеть" }); });
    }

    function showFieldErrors(root, j) {
      Array.prototype.forEach.call(root.querySelectorAll(".field-err"), function (el) {
        el.textContent = "";
      });
      if (j && j.ok === false && j.field) {
        var el = root.querySelector('[data-err-for="' + j.field + '"]');
        if (el) {
          el.textContent = j.error || "ошибка";
        }
      }
    }

    function wireIntakeForm(draftUrl, draft) {
      var form = view.querySelector(".intake-form");
      if (!form) { return; }
      var out = form.querySelector(".intake-msg");
      var trialOut = form.querySelector(".trial-out");
      var acceptBtn = form.querySelector("#intake-accept");
      var withNotes = form.querySelector("#intake-with-notes");
      var lastGreen = false;
      // проверка на лету (A.1): изменение любого поля → validate
      var timer = null;
      Array.prototype.forEach.call(form.querySelectorAll(".pf"), function (inp) {
        inp.addEventListener("change", function () {
          clearTimeout(timer);
          timer = setTimeout(function () {
            postIntake("/api/intake/" + encodeURIComponent(draftUrl) + "/validate", { passport: collectPassport(form, draft) }, function (status, j) {
              showFieldErrors(form, j);
            });
          }, 300);
        });
      });
      withNotes.addEventListener("change", function () {
        acceptBtn.disabled = !(lastGreen || withNotes.checked);
      });
      // пробный прогон (A.3): серверный, по страницам черновика
      form.querySelector("#intake-trial").addEventListener("click", function () {
        out.textContent = "Прогон…";
        postIntake("/api/intake/" + encodeURIComponent(draftUrl) + "/trialrun", {}, function (status, t) {
          if (status !== 200 || !t || t.ok !== true) {
            out.textContent = "Ошибка прогона: " + ((t && t.error) || status);
            return;
          }
          out.textContent = "";
          lastGreen = t.green === true;
          acceptBtn.disabled = !(lastGreen || withNotes.checked);
          trialOut.innerHTML = ACC.trialBlock(t);
        });
      });
      // «Принять на обслуживание» (A.4)
      acceptBtn.addEventListener("click", function () {
        out.textContent = "Создаём PR…";
        postIntake("/api/intake/" + encodeURIComponent(draftUrl) + "/accept", { passport: collectPassport(form, draft), with_notes: withNotes.checked }, function (status, j) {
          if (status === 200 && j && j.pr_url) {
            out.innerHTML = 'Создан PR: <a href="' + ACC.esc(j.pr_url) + '">' + ACC.esc(j.pr_url) + "</a>";
          } else {
            out.textContent = "Ошибка: " + ((j && j.error) || status);
          }
        });
      });
      form.querySelector("#intake-back").addEventListener("click", function () {
        render("intake");
      });
    }

    function wire(view) {
      // двухшаговое подтверждение операций и отправка формы
      Array.prototype.forEach.call(view.querySelectorAll(".op"), function (b) {
        b.addEventListener("click", function () {
          var card = b.closest(".reg-card") || b.closest(".reg-add");
          var conf = card && card.querySelector(".confirm");
          if (conf) {
            var go = conf.querySelector(".op-go");
            go.setAttribute("data-op", b.getAttribute("data-op"));
            go.setAttribute("data-id", b.getAttribute("data-id"));
            conf.classList.remove("hidden");
          }
        });
      });
      Array.prototype.forEach.call(view.querySelectorAll(".op-no"), function (b) {
        b.addEventListener("click", function () {
          b.closest(".confirm").classList.add("hidden");
        });
      });
      function postReg(kind, payload, out) {
        fetch("/api/registry/" + kind, {
          method: "POST",
          headers: { "X-ACC-Session": token, "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        }).then(function (r) {
          return r.json().then(function (j) { out(r.status, j); });
        }).catch(function () { out(0, { error: "сеть" }); });
      }
      Array.prototype.forEach.call(view.querySelectorAll(".op-go"), function (b) {
        b.addEventListener("click", function () {
          var kind = b.getAttribute("data-kind");
          var op = b.getAttribute("data-op");
          var id = b.getAttribute("data-id");
          postReg(kind, { op: op, id: id }, function (status, j) {
            if (status === 200 && j.pr_url) {
              view.querySelector(".pr-result") && (view.querySelector(".pr-result").innerHTML = 'Создан PR: <a href="' + ACC.esc(j.pr_url) + '">' + ACC.esc(j.pr_url) + "</a>");
            } else {
              view.querySelector(".pr-result") && (view.querySelector(".pr-result").textContent = "Ошибка: " + (j && j.error || status));
            }
          });
        });
      });
      Array.prototype.forEach.call(view.querySelectorAll(".op-add"), function (b) {
        b.addEventListener("click", function () {
          var card = b.closest(".reg-add");
          var kind = b.getAttribute("data-kind");
          var entry = { status: "active" };
          Array.prototype.forEach.call(card.querySelectorAll("input"), function (inp) {
            if (!inp.name) { return; }
            if (inp.name === "terms") {
              entry.terms_checked = /^да|yes|true$/i.test(inp.value);
            } else {
              entry[inp.name] = inp.value;
            }
          });
          var out = card.querySelector(".pr-result");
          postReg(kind, { op: "add", entry: entry }, function (status, j) {
            if (status === 200 && j.pr_url) {
              out.innerHTML = 'Создан PR: <a href="' + ACC.esc(j.pr_url) + '">' + ACC.esc(j.pr_url) + "</a>";
            } else {
              out.textContent = "Ошибка: " + (j && j.error || status);
            }
          });
        });
      });
    }

    function render(tab) {
      if (tab === "sites") {
        view.innerHTML = '<p class="msg">Загрузка…</p>';
        api("/api/sites", function (status, list) {
          if (status === 200) {
            view.innerHTML = ACC.renderSites(list);
            var btn = document.getElementById("refresh");
            if (btn) { btn.addEventListener("click", function () { render("sites"); }); }
          }
        });
        return;
      }
      if (tab === "intake") {
        view.innerHTML = '<p class="msg">Загрузка…</p>';
        api("/api/intake/drafts", function (status, list) {
          if (status === 200) {
            view.innerHTML = ACC.renderIntake(list);
            var rf = document.getElementById("intake-refresh");
            if (rf) { rf.addEventListener("click", function () { render("intake"); }); }
            Array.prototype.forEach.call(view.querySelectorAll(".intake-open"), function (b) {
              b.addEventListener("click", function () {
                var url = b.getAttribute("data-url");
                api("/api/intake/" + encodeURIComponent(url), function (s2, j) {
                  if (s2 === 200 && j && j.draft) {
                    view.innerHTML = ACC.intakeFormHtml(j.draft, ACC.passportFromDraft(j.draft));
                    wireIntakeForm(url, j.draft);
                  } else {
                    show("Черновик недоступен", true);
                  }
                });
              });
            });
          }
        });
        return;
      }
      if (tab === "models" || tab === "sources") {
        view.innerHTML = '<p class="msg">Загрузка…</p>';
        api("/api/registry/" + tab, function (status, list) {
          if (status === 200) {
            view.innerHTML = ACC.renderRegistry(tab, list);
            wire(view);
          }
        });
        return;
      }
      view.innerHTML = "";
      var card = document.createElement("div");
      card.className = "card";
      card.textContent = TITLES[tab] + " — скоро";
      view.appendChild(card);
    }

    Array.prototype.forEach.call(tabs.querySelectorAll(".tab"), function (b) {
      b.addEventListener("click", function () {
        Array.prototype.forEach.call(tabs.querySelectorAll(".tab"), function (x) {
          x.classList.remove("active");
        });
        b.classList.add("active");
        render(b.getAttribute("data-tab"));
      });
    });

    // токен из hash, hash стираем; проверка сессии
    var m = /^#s=(.+)$/.exec(window.location.hash);
    window.history.replaceState(null, "", window.location.pathname);
    token = m ? m[1] : "";
    if (!token) {
      show("Откройте АСС по ссылке от бота (/app)", true);
      return;
    }
    api("/api/whoami", function (status, j) {
      if (status === 200 && j && j.ok === true) {
        msg.hidden = true;
        tabs.hidden = false;
        render("sites");
      }
    });
  })();
}
