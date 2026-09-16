# Supabase stack integration layer

## Status

Not implemented. Restdis today caches only PostgREST (see `PRD.md`) and serves the Electric shape protocol (see `ELECTRIC_PRD.md`). Nothing described below — read replica preference as a general Postgres-origin setting, Storage/Auth/Realtime/Edge Function caching, or the `RT.FOLLOW`/`RT.CHANGES` commands — exists in the codebase yet. This document records the intended scope for that future work.

## Problem

Supabase is more than PostgREST: Realtime, Edge Functions, Auth, and Storage each make their own round trips to the database or to managed services, and each of those round trips is a candidate for the same cache-and-bust treatment Restdis already gives PostgREST. Today every one of those paths goes straight to origin on every request.

Restdis already owns the primitive that generalizes across all of them: an HTTP proxy that receives a `GET`, fetches it from origin, and caches the result under a WAL-invalidated key. The intent is to extend that primitive to the rest of the Supabase stack, plus a general "prefer read replica" tenant setting that would benefit every Postgres-backed integration, not just PostgREST.

## Intended scope

- A tenant-level "prefer read replica" setting applying to every Postgres-backed origin fetch (PostgREST, Auth, Storage metadata), generalized from the PostgREST-only `replica_url` routing that exists today.
- Additional PostgREST query-caching capabilities beyond single-query caching.
- Storage object/bucket metadata caching, WAL-busted on storage schema changes (file content caching is explicitly out of scope).
- Auth user-data caching with mandatory field-level redaction of sensitive data, excluding session/token tables entirely, WAL-busted on `auth.users` and configured related tables.
- Realtime "follow" commands (`RT.FOLLOW` / `RT.CHANGES`): a Redis-protocol front door onto `restdis_electric`'s shape log (not a new storage engine) for reading the last N changes to a channel or table.
- Edge Function `GET` caching, transparent when routed through Restdis.

## Explicitly out of scope

Caching non-`GET` methods on any of these origins; Realtime broadcast/presence channels (ephemeral, no backing table); full Storage file-content caching; automatic read-replica lag detection or failover (matching the existing PostgREST replica limitation); demo/reference integration harnesses for other stacks (Express, NGINX, etc.).

## Design constraint

Realtime follow mode must not become a fourth storage model alongside cached query responses, replicated key-value datasets, and the Electric shape log. It should be built as a Restdis-native client of `restdis_electric`'s existing shape log (via `RestdisElectric` / `RestdisElectric.Definition`, the same API `GET /v1/shape` uses), not a bespoke ring buffer.
