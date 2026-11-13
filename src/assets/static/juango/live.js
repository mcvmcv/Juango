// Juango live views (experimental): see src/contrib/live.jl.
//
// Each element with data-j-live (written by {% liveview %}) opens a WebSocket to its URL. The
// server renders the view again after every event and sends the HTML, which Idiomorph morphs
// into the page, keeping focus and what's being typed. Bindings, on elements inside the view:
//   j-click="name"                      a click; j-value-* attributes are sent as the parameters
//   j-submit="name"   (on a form)       the form's fields
//   j-change="name"                     input in a field (or any field of a form with it),
//                                       debounced by j-debounce milliseconds (default 150)
//   j-keydown="name"  [j-key="Enter"]   a key press: the key and the field's value
(function () {
  "use strict";

  function attrValues(el) {
    const v = {};
    for (const a of el.attributes) if (a.name.startsWith("j-value-")) v[a.name.slice(8)] = a.value;
    return v;
  }

  function formValues(form) {
    const v = {};
    new FormData(form).forEach(function (val, k) {
      if (typeof val !== "string") return;              // file inputs aren't sent over the socket
      v[k] = k in v ? [].concat(v[k], val) : val;
    });
    return v;
  }

  function connect(root) {
    const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + root.dataset.jLive;
    let ws = null, retries = 0;
    const timers = new WeakMap();

    function send(event, params) {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "event", event: event, params: params }));
    }

    function open() {
      ws = new WebSocket(url);
      ws.onopen = function () {
        retries = 0;
        root.classList.remove("j-disconnected");
        // (re)join: the server mounts the view again from the URL's query parameters
        ws.send(JSON.stringify({ type: "join", params: Object.fromEntries(new URLSearchParams(location.search)) }));
      };
      ws.onmessage = function (m) {
        const msg = JSON.parse(m.data);
        if (msg.type === "render") Idiomorph.morph(root, msg.html, { morphStyle: "outerHTML", ignoreActiveValue: true });
        else if (msg.type === "redirect") location.href = msg.url;
      };
      ws.onclose = function (e) {
        root.classList.add("j-disconnected");
        if (e.code === 4403) return;                     // refused: don't try again
        setTimeout(open, Math.min(10000, 200 * Math.pow(2, retries++)));
      };
    }

    root.addEventListener("click", function (e) {
      const el = e.target.closest("[j-click]");
      if (!el || !root.contains(el)) return;
      e.preventDefault();
      send(el.getAttribute("j-click"), attrValues(el));
    });
    root.addEventListener("submit", function (e) {
      const form = e.target.closest("form[j-submit]");
      if (!form || !root.contains(form)) return;
      e.preventDefault();
      send(form.getAttribute("j-submit"), Object.assign(formValues(form), attrValues(form)));
    });
    root.addEventListener("input", function (e) {
      const field = e.target;
      const el = field.closest("[j-change]") || (field.form && field.form.hasAttribute("j-change") ? field.form : null);
      if (!el || !root.contains(el)) return;
      const params = el.tagName === "FORM" ? formValues(el) : {};
      if (field.name) params[field.name] = field.value;
      params._target = field.name || "";
      clearTimeout(timers.get(el));
      timers.set(el, setTimeout(function () { send(el.getAttribute("j-change"), params); },
                                parseInt(el.getAttribute("j-debounce") || "150", 10)));
    });
    root.addEventListener("keydown", function (e) {
      const el = e.target.closest("[j-keydown]");
      if (!el || !root.contains(el)) return;
      const key = el.getAttribute("j-key");
      if (key && key !== e.key) return;
      send(el.getAttribute("j-keydown"), Object.assign({ key: e.key, value: e.target.value || "" }, attrValues(el)));
    });
    open();
  }

  function start() { document.querySelectorAll("[data-j-live]").forEach(connect); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
