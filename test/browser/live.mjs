// Drives headless Chromium over the DevTools protocol to test live.js against a running Juango
// server: node --experimental-websocket test/browser/live.mjs <base url> <upload file>
// Prints one JSON object with the results (test/browser.jl checks them).
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base, uploadPath] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), "juango-chromium-"));
const chrome = spawn(process.env.CHROMIUM || "chromium", ["--headless=new", "--disable-gpu", "--no-first-run",
  "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });

const endpoint = await new Promise((resolve, reject) => {
  let err = "";
  chrome.stderr.on("data", d => {
    err += d;
    const m = err.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) resolve(m[1]);
  });
  chrome.on("exit", code => reject(new Error("chromium exited: " + code + "\n" + err)));
  setTimeout(() => reject(new Error("chromium didn't start\n" + err)), 20000);
});

const ws = new WebSocket(endpoint);
await new Promise(r => ws.addEventListener("open", r, { once: true }));
let nextId = 0;
const pending = new Map();
ws.addEventListener("message", e => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});
function cmd(method, params = {}, sessionId) {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((resolve, reject) => pending.set(id, m => m.error ? reject(new Error(method + ": " + m.error.message)) : resolve(m.result)));
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

const results = {};
try {
  const { targetId } = await cmd("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cmd("Target.attachToTarget", { targetId, flatten: true });
  const s = (method, params) => cmd(method, params, sessionId);
  async function evaluate(expression) {
    const r = await s("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error("evaluate: " + JSON.stringify(r.exceptionDetails));
    return r.result.value;
  }
  async function waitFor(expression, ms = 8000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      if (await evaluate(expression)) return true;
      await sleep(50);
    }
    return false;
  }
  await s("Page.enable");
  await s("Runtime.enable");
  await s("Page.navigate", { url: base + "/browser/" });
  results.loaded = await waitFor("document.querySelector('#n') && document.querySelector('#n').textContent === '0'");
  results.connected = await waitFor("document.querySelector('#j-live').jConnects === 1");
  await sleep(300);                                         // the first render arrives

  // a click: the count goes up (a patch)
  await evaluate("document.querySelector('[j-click=inc]').click()");
  results.click = await waitFor("document.querySelector('#n').textContent === '1'");

  // typing: debounced j-change, the note follows and the field keeps the focus
  await evaluate("const i = document.querySelector('#note'); i.focus(); i.value = 'héllo 😀'; i.dispatchEvent(new Event('input', {bubbles: true})); true");
  results.typing = await waitFor("document.querySelector('#shown').textContent === 'héllo 😀'");
  results.focus = await evaluate("document.activeElement && document.activeElement.id === 'note'");

  // a failing handler closes the socket; the browser reconnects with its snapshot and keeps the state
  await evaluate("document.querySelector('[j-click=drop]').click()");
  results.reconnected = await waitFor("document.querySelector('#j-live').jConnects === 2");
  await sleep(300);                                         // the render after joining again
  results.reconnect_keeps_state = await waitFor("document.querySelector('#n').textContent === '1' && document.querySelector('#shown').textContent === 'héllo 😀'");
  await evaluate("document.querySelector('[j-click=inc]').click()");
  results.after_reconnect = await waitFor("document.querySelector('#n').textContent === '2'");

  // a file in a j-submit form goes over the socket
  const { root } = await s("DOM.getDocument");
  const { nodeId } = await s("DOM.querySelector", { nodeId: root.nodeId, selector: "#file" });
  await s("DOM.setFileInputFiles", { nodeId, files: [uploadPath] });
  await evaluate("document.querySelector('#upload').requestSubmit(); true");
  results.upload = await waitFor("document.querySelector('#files').textContent.includes('sample.txt:')");
  results.files_text = await evaluate("document.querySelector('#files').textContent");
} catch (e) {
  results.error = String(e && e.stack || e);
} finally {
  console.log(JSON.stringify(results));
  try { ws.close(); } catch {}
  chrome.kill();
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
