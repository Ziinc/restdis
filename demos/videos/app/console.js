// An in-page console, like a docked DevTools panel. It wraps window.fetch and
// console.log so every request the app fires shows up with its status, the
// Restdis cache header, and how long the response took. Electric shape
// requests show as "polling" while Restdis holds them open, and list the
// changes each one delivered underneath.
//
// Writes made by "another user" in the demos use window.rawFetch, so they do
// not appear here: they are not this app's requests.

const panel = document.createElement("div");
panel.id = "console";
panel.innerHTML = `<div class="console-bar"><span class="tab">Console</span><span class="hint">fetch() and console.log from this page</span></div><div class="console-body"></div>`;
const body = panel.querySelector(".console-body");
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => document.body.appendChild(panel));
} else {
  document.body.appendChild(panel);
}

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

function row(html, cls = "") {
  const el = document.createElement("div");
  el.className = `line flash ${cls}`;
  el.innerHTML = html;
  body.appendChild(el);
  body.scrollTop = body.scrollHeight;
  return el;
}

function describe(u) {
  const params = new URLSearchParams(u.search);
  // Shape requests carry long handles and cursors; keep what a reader needs.
  if (u.pathname.endsWith("/v1/shape")) {
    const keep = ["shape", "table", "offset", "live"]
      .filter((k) => params.has(k))
      .map((k) => `${k}=${params.get(k)}`);
    return `${u.pathname}?${keep.join("&")}`;
  }
  // Decode twice: Restdis's path parameter is itself an encoded PostgREST query.
  return decodeURIComponent(decodeURIComponent(u.pathname + u.search));
}

const seconds = (ms) => (ms < 1000 ? `${ms.toFixed(1)} ms` : `${(ms / 1000).toFixed(1)} s`);

function changeLine(msg) {
  if (msg.headers?.control) return `<span class="ctl">${esc(msg.headers.control)}</span>`;
  const op = msg.headers?.operation ?? "?";
  const key = msg.key?.replace(/^"|"$/g, "");
  const value = op === "delete" ? "" : ` ${esc(JSON.stringify(msg.value))}`;
  return `<span class="op ${op}">${op}</span> id=${esc(key)}${value}`;
}

async function nestShapeMessages(res, after) {
  let messages = [];
  try {
    messages = await res.clone().json();
  } catch {
    return 0;
  }
  let anchor = after;
  let changes = 0;
  for (const msg of messages) {
    if (!msg.headers?.control) changes++;
    const el = document.createElement("div");
    el.className = "line nested flash";
    el.innerHTML = `<span class="tree">└</span> ${changeLine(msg)}`;
    anchor.after(el);
    anchor = el;
  }
  body.scrollTop = body.scrollHeight;
  return changes;
}

const rawFetch = window.fetch.bind(window);
window.rawFetch = rawFetch;

window.fetch = async (input, init = {}) => {
  const u = new URL(typeof input === "string" ? input : input.url, location.href);
  const method = (init.method ?? "GET").toUpperCase();
  const isShape = u.pathname.endsWith("/v1/shape");
  const live = u.searchParams.get("live") === "true";
  const started = performance.now();
  const state = isShape ? (live ? "polling" : "snapshot") : "fetching";
  // The demo tags each Electric client with an x-demo-client header.
  const client = new Headers(init.headers).get("x-demo-client");
  const tag = client ? `<span class="tag ${esc(client)}">${esc(client)}</span> ` : "";
  const el = row(
    `<span class="dir">${live ? "↻" : "→"}</span> ${tag}<b>${method}</b> <span class="url">${esc(describe(u))}</span><span class="result waiting">${state} <span class="t">0.0 ms</span></span>`,
    "req"
  );
  const result = el.querySelector(".result");
  const tick = setInterval(() => {
    result.querySelector(".t").textContent = seconds(performance.now() - started);
  }, 100);
  try {
    const res = await rawFetch(input, init);
    clearInterval(tick);
    const ms = performance.now() - started;
    const cache = res.headers.get("rd-cache");
    const changes = isShape && res.ok ? await nestShapeMessages(res, el) : null;
    result.className = "result";
    result.innerHTML =
      `<span class="status s${String(res.status)[0]}">${res.status}</span>` +
      (cache ? ` <span class="badge ${cache}">${cache}</span>` : "") +
      (changes !== null ? ` <span class="count">${changes} change${changes === 1 ? "" : "s"}</span>` : "") +
      ` <span class="t">${seconds(ms)}</span>`;
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
