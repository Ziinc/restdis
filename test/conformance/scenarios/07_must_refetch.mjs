// must-refetch: RestdisElectric returns 409 with a `location` header
// pointing at a fresh handle when a client's handle/offset is no longer
// valid (electric.ex's send_must_refetch/2). Exercised two ways: the raw
// documented HTTP contract, and proof the real client self-heals from it.

import { BASE_URL, API_KEY, newStream, collect, waitUntil, assert } from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({ table: "conformance_items", where: "id >= 70 AND id < 80" });
  const { seen, unsubscribe } = collect(stream);
  await waitUntil(() => stream.isUpToDate);
  const handle = stream.shapeHandle;
  const offset = stream.lastOffset;
  unsubscribe();

  // Force the shape to become invalid by deleting it server-side (the
  // tenant fixture sets allow_shape_deletion: true).
  const deleteResponse = await fetch(
    `${BASE_URL}/v1/shape?handle=${encodeURIComponent(handle)}`,
    { method: "DELETE", headers: { authorization: `Bearer ${API_KEY}` } }
  );
  assert(deleteResponse.status === 202, `DELETE /v1/shape returned ${deleteResponse.status}`);

  // Raw contract: resuming with the now-deleted handle/offset must 409 with
  // a `location` pointing at a fresh handle.
  const resumeUrl = new URL(`${BASE_URL}/v1/shape`);
  resumeUrl.searchParams.set("table", "conformance_items");
  resumeUrl.searchParams.set("where", "id >= 70 AND id < 80");
  resumeUrl.searchParams.set("handle", handle);
  resumeUrl.searchParams.set("offset", offset);
  const resumeResponse = await fetch(resumeUrl, {
    headers: { authorization: `Bearer ${API_KEY}` },
  });
  assert(resumeResponse.status === 409, `expected 409 must-refetch, got ${resumeResponse.status}`);
  const location = resumeResponse.headers.get("location");
  assert(location, "409 must-refetch response had no location header");
  assert(location.includes("offset=-1"), `location did not point at a fresh snapshot: ${location}`);

  // The real client self-heals: a stream resuming from the invalidated
  // handle/offset transparently rotates to a new handle and still reaches
  // up-to-date with the current data, without the caller having to notice.
  const healed = newStream(
    { table: "conformance_items", where: "id >= 70 AND id < 80" },
    { handle, offset }
  );
  const healedSeen = collect(healed);
  await waitUntil(() => healed.isUpToDate, { timeoutMs: 20_000 });
  assert(
    healed.shapeHandle && healed.shapeHandle !== handle,
    "stream did not rotate to a new shape handle after must-refetch"
  );
  healedSeen.unsubscribe();
}
