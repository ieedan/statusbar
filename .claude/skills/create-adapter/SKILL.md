---
name: create-adapter
description: Scaffold a new Site Status adapter — a TypeScript plugin that teaches the app to read a new site's status. Use when the user wants to add support for a status source that isn't covered by the built-in statuspage/aws adapters, or says "create/add an adapter for <site>".
---

# Create a Site Status adapter

Adapters live in `adapters/<id>/` and are **pure parsers**: the app fetches, the
adapter only decides the URL (`endpoint`) and normalizes the body (`parse`). Read
[`adapters/README.md`](../../../adapters/README.md) for the full contract before
starting.

## Steps

1. **Identify the status source.** Ask the user for the site and its status page
   URL if not given. Determine the provider:
   - If `curl -sL <url>/api/v2/summary.json` returns JSON with a `status.indicator`,
     it's an **Atlassian Statuspage** — it's already handled by the `statuspage`
     adapter. Don't create a new adapter; just add a `suggestedSites` entry to
     `adapters/statuspage/src/index.ts` (or tell the user to Add Custom in Settings
     with adapter `statuspage`).
   - Otherwise inspect the real response (`curl`) to learn its JSON shape. That
     shape drives `parse`.

2. **Scaffold the directory** `adapters/<id>/` with:
   - `adapter.json` — `{ "id", "name", "description", "entry": "dist/index.js" }`
   - `package.json` — copy from `adapters/aws/package.json`, change the name; keep
     the `@status-bar/adapter-sdk` workspace dependency.
   - `tsconfig.json` — copy from `adapters/aws/tsconfig.json`.
   - `src/index.ts` — the adapter (see below).
   Add the package to `adapters/pnpm-workspace.yaml`.

3. **Write `src/index.ts`.** Start from the template in `adapters/README.md`.
   - Map the source's states to `StatusLevel` (`operational | minor | major | unknown`).
   - Emit one `issue` per active problem (`{ component?, title, level? }`); the app
     de-duplicates by title, so per-component issues are fine.
   - Return `{ level, detail, issues }`.
   - Add a `suggestedSites` entry so it appears in Settings' Add menu.
   - Base every mapping on the **actual** response you fetched, not assumptions.

4. **Build and type-check:**
   ```sh
   make adapters
   pnpm -C adapters typecheck
   ```

5. **Test `parse` against the real response** (pure function, so this is easy):
   ```sh
   curl -sL "<real status url>" > /tmp/fixture.json
   node -e "require('./adapters/<id>/dist/index.js'); \
     const a=globalThis.__STATUSBAR_ADAPTER__; \
     console.log(JSON.stringify(a.parse(require('fs').readFileSync('/tmp/fixture.json','utf8'),{baseURL:''}),null,2))"
   ```
   Confirm `level`, `detail`, and `issues` look right for the current live state.

6. **Verify end-to-end** through the Swift runtime:
   ```sh
   make check
   ```
   The new site should appear with the right shape/detail (add it to config or via
   Settings first, using the new adapter id).

## Quick path: a single plain-JS file (no build)

If the user just wants a one-off adapter (not a contribution to this repo), skip
the TypeScript scaffold entirely. The app injects `defineAdapter` as a global, so
a lone `.js` file works with no toolchain:

```js
defineAdapter({
  id: "example",
  name: "Example",
  endpoint: (base) => base + "/status.json",
  parse: (body) => { const d = JSON.parse(body); return { level: d.ok ? "operational" : "major", detail: d.message }; },
  suggestedSites: [{ id: "example", name: "Example", url: "https://example.com" }],
});
```

Install it with **Settings → Adapters… → Install Adapter…** (or drop it into the
Reveal-ed adapters folder). Verify with `StatusBar --adapters`.

## Notes

- Adapters get **no** network or filesystem access — everything comes from the
  `body` string. If a source needs multiple requests or auth headers, it can't be
  a pure-parser adapter; flag that to the user.
- Keep `parse` defensive: use `?.` and `?? []` so a missing field yields
  `unknown`/empty rather than throwing.
- A user can install an adapter by copying `adapters/<id>/` (with `dist/`) into
  `~/Library/Application Support/StatusBar/adapters/`.
