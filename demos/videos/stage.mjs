// Stage server for the recorded demos.
//
// Serves a split-screen page: the client under test on the left, and on the
// right the live Restdis request log and the live Postgres statement log, read
// straight from `docker compose logs`. Same-origin proxies to Restdis and
// PostgREST keep the browser apps free of CORS setup.
//
//   node stage.mjs            then open http://localhost:5180/?demo=query
//                                                 (or demo=db, demo=redis)

import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import http from "node:http";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.STAGE_PORT ?? 5180);
const RESTDIS_URL = process.env.RESTDIS_URL ?? "http://localhost:4042";
const PGRST_URL = process.env.PGRST_URL ?? "http://localhost:3002";

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

// Postgres log entries span several lines; a new one starts with a timestamp.
const PG_ENTRY = /^\d{4}-\d{2}-\d{2} [\d:.]+ \w+ \[(.*?)\]\s*(\w+):\s+(.*)$/;
const DEMO_TABLES = /\b(products|todos)\b/;

function sse(res) {
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });
  return (event) => res.write(`data: ${JSON.stringify(event)}\n\n`);
}

// `since` is pinned to when the browser subscribed, so lines written while
// `docker compose logs` is still attaching are not lost.
function followService(service, onLine) {
  const since = new Date(Date.now() - 500).toISOString();
  const child = spawn("docker", ["compose", "logs", "-f", "--since", since, "--no-log-prefix", service], {
    cwd: here,
  });
  let buffer = "";
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop();
    lines.forEach(onLine);
  });
  return child;
}

function streamPostgres(req, res) {
  const send = sse(res);
  send({ ready: true });
  let entry = null;
  const flush = () => {
    if (!entry) return;
    const sql = entry.text.replace(/\s+/g, " ").trim();
    if (entry.level === "LOG" && DEMO_TABLES.test(sql)) {
      // Postgrex connections (Restdis) set no application_name.
      const app = entry.app === "[unknown]" ? "restdis" : entry.app;
      send({ app, sql: sql.replace(/^(statement|execute [^:]*):\s*/, "") });
    }
    entry = null;
  };
  const child = followService("db", (line) => {
    const m = line.match(PG_ENTRY);
    if (m) {
      flush();
      entry = { app: m[1], level: m[2], text: m[3] };
    } else if (entry) {
      entry.text += " " + line;
    }
  });
  const timer = setInterval(flush, 200);
  req.on("close", () => {
    clearInterval(timer);
    child.kill();
  });
}

function streamRestdis(req, res) {
  const send = sse(res);
  send({ ready: true });
  // Plug.Logger writes a request line then a "Sent" line; drop both for /health.
  let skipSent = false;
  const child = followService("restdis", (line) => {
    if (/\[info\] (GET|POST|PATCH|DELETE) \//.test(line)) {
      skipSent = line.includes("/health");
      if (!skipSent) send({ line });
    } else if (/\[info\] Sent \d{3}/.test(line) && !skipSent) {
      send({ line });
    }
  });
  req.on("close", () => child.kill());
}

function streamRedisClient(req, res) {
  const send = sse(res);
  const child = spawn(process.execPath, [join(here, "redis-client.mjs")], { cwd: here, env: process.env });
  child.stdout.on("data", (chunk) => send({ text: chunk.toString() }));
  child.stderr.on("data", (chunk) => send({ text: chunk.toString() }));
  child.on("exit", () => send({ done: true }));
  req.on("close", () => child.kill());
}

function proxy(req, res, base, prefix) {
  const target = new URL(req.url.slice(prefix.length) || "/", base);
  const upstream = http.request(
    target,
    { method: req.method, headers: { ...req.headers, host: target.host } },
    (up) => {
      res.writeHead(up.statusCode, up.headers);
      up.pipe(res);
    }
  );
  upstream.on("error", (err) => {
    res.writeHead(502);
    res.end(String(err));
  });
  req.pipe(upstream);
}

async function serveFile(res, path) {
  try {
    const body = await readFile(join(here, path));
    res.writeHead(200, { "content-type": TYPES[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
}

http
  .createServer((req, res) => {
    const { pathname } = new URL(req.url, "http://stage");
    if (pathname.startsWith("/restdis/")) return proxy(req, res, RESTDIS_URL, "/restdis");
    if (pathname.startsWith("/rest/")) return proxy(req, res, PGRST_URL, "/rest");
    if (pathname === "/logs/postgres") return streamPostgres(req, res);
    if (pathname === "/logs/restdis") return streamRestdis(req, res);
    if (pathname === "/run/redis") return streamRedisClient(req, res);
    if (pathname === "/") return serveFile(res, "app/stage.html");
    if (pathname === "/app/query") return serveFile(res, "app/query.html");
    if (pathname === "/app/db") return serveFile(res, "app/db.html");
    if (pathname.startsWith("/dist/") || pathname.startsWith("/app/")) return serveFile(res, pathname.slice(1));
    res.writeHead(404);
    res.end("not found");
  })
  .listen(PORT, () => console.log(`stage on http://localhost:${PORT}`));
