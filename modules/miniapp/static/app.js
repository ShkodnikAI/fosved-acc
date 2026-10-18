// АСС Mini App — каркас (наряд АСС-2.2, A.2). Без внешних ресурсов.
// Токен: из location.hash (#s=…), hash стирается сразу (history.replaceState),
// уходит заголовком X-ACC-Session на все /api/*. Не хранится в localStorage
// и cookie — живёт в памяти страницы.
(function () {
  "use strict";
  var msg = document.getElementById("msg");
  var tabs = document.getElementById("tabs");
  var view = document.getElementById("view");

  // 1) токен из hash, hash стираем
  var m = /^#s=(.+)$/.exec(window.location.hash);
  window.history.replaceState(null, "", window.location.pathname);
  var token = m ? m[1] : "";

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

  var TITLES = {
    sites: "Сайты",
    models: "Модели",
    sources: "Источники"
  };

  function render(tab) {
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

  // 2) проверка сессии
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
