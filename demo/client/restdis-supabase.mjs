// Thin wrapper around the real @supabase/supabase-js client for the demo
// stack (../docker-compose.yml). It changes nothing about how the client
// behaves normally: `.from(table).select(columns)` goes straight to
// PostgREST exactly like the real supabase-js does.
//
// The only addition is a `cache` option on `select()`. When present, the
// request is *not* sent to the real client at all: it's rebuilt as a
// Restdis `/pgrst/query` call instead, which is what proves the
// interception rather than just calling PostgREST a second way. Restdis's
// tenant config (not this option) is the actual source of truth for TTL;
// `cache` here only has to parse to something sane before we bother
// intercepting.
//
// Not shipped code - this exists to demonstrate SUPABASE_INTEGRATION_PRD.md's
// caching primitive against a real supabase-js call shape, for the demo
// script and screen recording.

import { createClient } from "@supabase/supabase-js";

const TTL_PATTERN = /^(\d+)(ms|s|m)$/;

/**
 * @param {string} supabaseUrl - the real PostgREST/Supabase origin (unused
 *   for intercepted requests, used as-is for everything else).
 * @param {string} supabaseKey - passed straight through to supabase-js.
 * @param {{ restdisUrl?: string, restdisApiKey?: string }} [options]
 */
export function createRestdisClient(supabaseUrl, supabaseKey, options = {}) {
  const real = createClient(supabaseUrl, supabaseKey);
  const restdis = {
    url: options.restdisUrl ?? process.env.RESTDIS_URL ?? "http://localhost:4041",
    apiKey: options.restdisApiKey ?? process.env.DEMO_API_KEY ?? "sk_demo",
  };

  return {
    /** Escape hatch to the real, unwrapped client. */
    raw: real,

    from(table) {
      return {
        /**
         * @param {string} [columns]
         * @param {{ cache?: string } & Record<string, unknown>} [selectOptions]
         */
        select(columns = "*", selectOptions = {}) {
          const { cache, ...postgrestOptions } = selectOptions;

          if (!cache) {
            return real.from(table).select(columns, postgrestOptions);
          }

          parseTtlMs(cache); // throws on a malformed value before we intercept anything
          return fetchThroughRestdis(restdis, table, columns, cache);
        },
      };
    },
  };
}

function parseTtlMs(cache) {
  const match = TTL_PATTERN.exec(cache);
  if (!match) {
    throw new Error(`invalid cache option "${cache}", expected e.g. "30s", "500ms", "5m"`);
  }
  const [, amount, unit] = match;
  return Number(amount) * { ms: 1, s: 1000, m: 60_000 }[unit];
}

async function fetchThroughRestdis(restdis, table, columns, cache) {
  const postgrestPath = `${table}?select=${columns}`;
  const url = `${restdis.url}/pgrst/query?path=${encodeURIComponent(postgrestPath)}`;

  const res = await fetch(url, {
    headers: { authorization: `Bearer ${restdis.apiKey}` },
  });
  const body = await res.json();

  const meta = {
    intercepted: true,
    via: "restdis",
    cache,
    cacheStatus: res.headers.get("sc-cache"),
    cacheTtlRemaining: res.headers.get("sc-cache-ttl"),
  };

  if (!res.ok) {
    return { data: null, error: body, status: res.status, ...meta };
  }
  return { data: body, error: null, status: res.status, ...meta };
}
