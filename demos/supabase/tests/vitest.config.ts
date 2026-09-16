import { defineConfig } from "vitest/config";

// Separate config from any config the umbrella app's own tests use: this
// suite only verifies Restdis's Supabase integration points (PostgREST,
// GoTrue) against the stack in demos/supabase/docker-compose.yml, and is run by its
// own workflow (.github/workflows/supabase-integration.yml), not the
// Elixir `mix test` gate.
export default defineConfig({
  test: {
    globalSetup: ["./globalSetup.ts"],
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
