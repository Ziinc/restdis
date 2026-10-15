// A fetch adapter for supabase-js. Reads (GET /rest/v1/...) go to Restdis's
// /pgrst/query endpoint, which caches them. Everything else goes to PostgREST
// unchanged. Pass it as `global.fetch` to createClient.
const RESTDIS = "/restdis";
const POSTGREST = "/rest";
const API_KEY = "sk_demo";

export function restdisFetch(input, init = {}) {
  const url = new URL(typeof input === "string" ? input : input.url);
  const path = url.pathname.replace(/^.*\/rest\/v1\//, "") + url.search;
  const method = (init.method ?? "GET").toUpperCase();

  if (method === "GET") {
    return fetch(`${RESTDIS}/pgrst/query?path=${encodeURIComponent(path)}`, {
      headers: { authorization: `Bearer ${API_KEY}` },
      signal: init.signal,
    });
  }
  return fetch(`${POSTGREST}/${path}`, init);
}
