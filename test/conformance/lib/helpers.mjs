import { ShapeStream } from "@electric-sql/client";
import pg from "pg";

export const BASE_URL = process.env.RESTDIS_URL ?? "http://localhost:4040";
export const API_KEY = process.env.RESTDIS_API_KEY ?? "sk_conformance";
export const DATABASE_URL =
  process.env.CONFORMANCE_DATABASE_URL ??
  "postgres://postgres:postgres@localhost:5432/restdis_dev";

export class ConformanceError extends Error {}

export function assert(condition, message) {
  if (!condition) throw new ConformanceError(message);
}

export function newStream(params, extra = {}) {
  return new ShapeStream({
    url: `${BASE_URL}/v1/shape`,
    params,
    headers: { authorization: `Bearer ${API_KEY}` },
    ...extra,
  });
}

// Subscribes once and appends every message to `seen`. Callers poll `seen`
// with `waitUntil` instead of matching per-call batches, so assertions can
// look at the whole history a shape produced, not just one delivery.
export function collect(stream) {
  const seen = [];
  const unsubscribe = stream.subscribe((messages) => seen.push(...messages));
  return { seen, unsubscribe };
}

export async function waitUntil(predicate, { timeoutMs = 15_000, intervalMs = 100 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const result = predicate();
    if (result) return result;
    if (Date.now() >= deadline) {
      throw new ConformanceError(`timed out after ${timeoutMs}ms waiting for condition`);
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

export async function withPg(fn) {
  const client = new pg.Client({ connectionString: DATABASE_URL });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

export async function pgQuery(sql, params) {
  return withPg((client) => client.query(sql, params));
}

export function inserts(seen) {
  return seen.filter((m) => m.headers?.operation === "insert");
}

export function updates(seen) {
  return seen.filter((m) => m.headers?.operation === "update");
}

export function deletes(seen) {
  return seen.filter((m) => m.headers?.operation === "delete");
}

export function byId(messages, id) {
  return messages.filter((m) => m.value?.id === id || m.old_value?.id === id);
}
