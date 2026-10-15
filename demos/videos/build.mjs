// Bundles the two browser apps into dist/ for stage.mjs to serve.
import { build } from "esbuild";

await build({
  entryPoints: { query: "app/query.jsx", db: "app/db.jsx" },
  outdir: "dist",
  bundle: true,
  format: "esm",
  jsx: "automatic",
  minify: true,
  define: { "process.env.NODE_ENV": '"production"' },
  logLevel: "info",
});
