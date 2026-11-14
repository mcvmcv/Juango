// Juango live views (experimental): see src/contrib/live.jl.
//
// Each element with data-j-live (written by {% liveview %}) opens a WebSocket to its URL. The
// server renders the view again after every event and sends what changed (a patch against the
// last HTML this page has, or the whole part); Idiomorph morphs it into the page, keeping focus
// and what's being typed. Bindings, on elements inside the view:
//   j-click="name"                      a click; j-value-* attributes are sent as the parameters
//   j-submit="name"   (on a form)       the form's fields (files are uploaded over the socket first)
//   j-change="name"                     input in a field (or any field of a form with it),
//                                       debounced by j-debounce milliseconds (default 150)
//   j-keydown="name"  [j-key="Enter"]   a key press: the key and the field's value
(function () {
  "use strict";

  const CHUNK = 49152;                    // bytes of a file per upload message

  function attrValues(el) {
    const v = {};
    for (const a of el.attributes) if (a.name.startsWith("j-value-")) v[a.name.slice(8)] = a.value;
    return v;
  }

  function formValues(form) {
    const v = {};
    new FormData(form).forEach(function (val, k) {
      if (typeof val !== "string") return;              // files go separately (uploadFiles)
      v[k] = k in v ? [].concat(v[k], val) : val;
    });
    return v;
  }

  function toBase64(buf) {
    let s = "";
    const bytes = new Uint8Array(buf);
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }

  function connect(root) {
    const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + root.dataset.jLive;
    let ws = null, retries = 0, html = null, seq = 0, snap = null, uploads = 0;
    const timers = new WeakMap();

    function sendRaw(msg) {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
    }
    function send(event, params) { sendRaw({ type: "event", event: event, params: params }); }

    function apply(newHtml) {
      html = newHtml;
      Idiomorph.morph(root, newHtml, { morphStyle: "outerHTML", ignoreActiveValue: true });
    }

    // a form's files, in chunks; then the parameters name each one as {"__upload__": ref}
    async function uploadFiles(form, params) {
      for (const input of form.querySelectorAll("input[type=file]")) {
        if (!input.name || !input.files.length) continue;
        const refs = [];
        for (const file of input.files) {
          const ref = "u" + (++uploads) + "-" + Date.now();
          for (let off = 0; off === 0 || off < file.size; off += CHUNK) {
            const buf = await file.slice(off, off + CHUNK).arrayBuffer();
            sendRaw({ type: "upload", ref: ref, name: file.name, content_type: file.type || "application/octet-stream",
                      chunk: toBase64(buf), last: off + CHUNK >= file.size });
          }
          refs.push({ __upload__: ref });
        }
        params[input.name] = input.multiple ? refs : refs[0];
      }
      return params;
    }

    function open() {
      ws = new WebSocket(url);
      ws.onopen = function () {
        retries = 0;
        root.classList.remove("j-disconnected");
        root.jConnects = (root.jConnects || 0) + 1;      // (for tests and debugging; not an attribute: morphing resets those)
        // (re)join: the server mounts the view again from the URL's query parameters (and the
        // snapshot of its state, for views that keep one)
        const join = { type: "join", diff: true, params: Object.fromEntries(new URLSearchParams(location.search)) };
        if (snap) join.snap = snap;
        html = null;
        ws.send(JSON.stringify(join));
      };
      ws.onmessage = function (m) {
        const msg = JSON.parse(m.data);
        if (msg.snap) snap = msg.snap;
        if (msg.type === "render") {
          apply(msg.html);
          seq = msg.seq;
        } else if (msg.type === "patch") {
          if (html === null || msg.base !== seq) { sendRaw({ type: "resync" }); return; }
          apply(html.slice(0, msg.start) + msg.ins + html.slice(msg.start + msg.del));
          seq = msg.seq;
        } else if (msg.type === "redirect") {
          location.href = msg.url;
        }
      };
      ws.onclose = function (e) {
        root.classList.add("j-disconnected");
        if (e.code === 4403 || e.code === 4429) return;   // refused, or too many open: don't try again
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
      const name = form.getAttribute("j-submit");
      uploadFiles(form, Object.assign(formValues(form), attrValues(form))).then(function (params) { send(name, params); });
    });
    root.addEventListener("input", function (e) {
      const field = e.target;
      if (field.type === "file") return;
      const el = field.closest("[j-change]") || (field.form && field.form.hasAttribute("j-change") ? field.form : null);
      if (!el || !root.contains(el)) return;
      const params = el.tagName === "FORM" ? formValues(el) : {};
      if (field.name) params[field.name] = field.type === "checkbox" ? (field.checked ? field.value : "") : field.value;
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
