// An in-page console, like a docked DevTools panel. It wraps window.fetch and
// console.log so every request the app fires shows up with its status, the
// Restdis cache header, and how long the response took.
//
// Writes made by "another user" in the demos use window.rawFetch, so they do
// not appear here: they are not this app's requests.

const panel = document.createElement("div");
panel.id = "console";
panel.innerHTML = `<div class="console-bar"><span class="tab">Console</span><span class="hint">fetch() and console.log from this page</span></div><div class="console-body"></div>`;
const body = panel.querySelector(".console-body");
document.addEventListener("DOMContentLoaded", () => document.body.appendChild(panel));
if (document.readyState !== "loading") document.body.appendChild(panel);

function row(html, cls = "") {
  const el = document.createElement("div");
  el.className = `line flash ${cls}`;
  el.innerHTML = html;
  body.appendChild(el);
  body.scrollTop = body.scrollHeight;
  return el;
}

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

function describe(url) {
  const u = new URL(url, location.href);
  // Decode twice: Restdis's path parameter is itself an encoded PostgREST query.
  return decodeURIComponent(decodeURIComponent(u.pathname + u.search));
}

const rawFetch = window.fetch.bind(window);
window.rawFetch = rawFetch;

window.fetch = async (input, init = {}) => {
  const url = typeof input === "string" ? input : input.url;
  const method = (init.method ?? "GET").toUpperCase();
  const started = performance.now();
  const el = row(
    `<span class="dir">→</span> <b>${method}</b> <span class="url">${esc(describe(url))}</span><span class="result pending">pending <span class="t">0 ms</span></span>`,
    "req"
  );
  const result = el.querySelector(".result");
  const tick = setInterval(() => {
    result.querySelector(".t").textContent = `${Math.round(performance.now() - started)} ms`;
  }, 100);
  try {
    const res = await rawFetch(input, init);
    clearInterval(tick);
    const ms = (performance.now() - started).toFixed(1);
    const cache = res.headers.get("sc-cache");
    result.className = "result";
    result.innerHTML =
      `<span class="status s${String(res.status)[0]}">${res.status}</span>` +
      (cache ? ` <span class="badge ${cache}">${cache}</span>` : "") +
      ` <span class="t">${ms} ms</span>`;
    el.classList.add("settled");
    return res;
  } catch (err) {
    clearInterval(tick);
    result.className = "result error";
    result.textContent = err.name === "AbortError" ? "aborted" : String(err);
    throw err;
  }
};

const log = console.log.bind(console);
console.log = (...args) => {
  log(...args);
  row(`<span class="dir">›</span> ${esc(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "))}`, "log");
};
