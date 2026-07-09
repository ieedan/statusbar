// Builds every adapter (any directory containing an adapter.json) from
// src/index.ts into a single self-contained IIFE bundle at its manifest `entry`.
import { build } from "esbuild";
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

const adapterDirs = readdirSync(root, { withFileTypes: true })
  .filter((d) => d.isDirectory() && existsSync(join(root, d.name, "adapter.json")))
  .map((d) => join(root, d.name));

if (adapterDirs.length === 0) {
  console.error("No adapters found (looked for */adapter.json).");
  process.exit(1);
}

for (const dir of adapterDirs) {
  const manifest = JSON.parse(readFileSync(join(dir, "adapter.json"), "utf8"));
  const outfile = join(dir, manifest.entry ?? "dist/index.js");
  await build({
    entryPoints: [join(dir, "src/index.ts")],
    outfile,
    bundle: true,
    format: "iife",
    platform: "neutral",
    target: "es2020",
    legalComments: "none",
  });
  console.log(`built ${manifest.id} -> ${outfile.replace(root + "/", "")}`);
}
