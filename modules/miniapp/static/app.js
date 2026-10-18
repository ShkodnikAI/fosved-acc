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

  renderSites: function (list) {
    if (!list || !list.length) {
      return '<div class="empty">Сайтов на обслуживании нет</div>' +
        '<button class="tab" id="refresh">Обновить</button>';
    }
    var self = this;
    return list.map(function (s) { return self.siteCard(s); }).join("") +
      '<button class="tab" id="refresh">Обновить</button>';
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

    var TITLES = { sites: "Сайты", models: "Модели", sources: "Источники" };

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
