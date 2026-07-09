---
name: add-site
description: Add a site to StatusBar. If an existing adapter already covers it (Statuspage, AWS, GCP, …) just add the site; otherwise scaffold a new adapter for it. Use when the user says "add <site> to my statusbar", "monitor <site>", or "create/add an adapter for <site>".
---

# Add a site to StatusBar

The goal is to get the user's site monitored with the **least** work. Most sites
are already covered by an existing adapter — in that case you just add the site,
no new code. Only scaffold a new adapter when nothing existing can read the
source. Adapters live in `adapters/<id>/` and are **pure parsers**: the app
fetches, the adapter only decides the URL (`endpoint`) and normalizes the body
(`parse`). Read [`adapters/README.md`](../../../adapters/README.md) for the full
contract.

## Steps

1. **Identify the site and its status URL.** Ask the user for the site and its
   status page URL if not given.

2. **Check whether an existing adapter already covers it.** In order:
   - **Statuspage** — if `curl -sL <url>/api/v2/summary.json` returns JSON with a
     `status.indicator`, the built-in `statuspage` adapter handles it. This covers
     most large providers (GitLab, GitHub, Cloudflare, …).
   - **AWS / GCP** — the `aws` and `gcp` adapters cover those clouds' native feeds.
   - Skim the `suggestedSites` arrays in `adapters/*/src/index.ts` in case it's
     already listed.

   If an existing adapter covers it, **don't write any new adapter code.** Add the
   site one of two ways:
   - Add a `suggestedSites` entry to that adapter's `src/index.ts` (e.g. a new
     Statuspage site goes in `adapters/statuspage/src/index.ts`) so it shows up in
     Settings' **+** menu for everyone, then `make adapters`.
   - Or tell the user to add it themselves via **Settings → Add Custom…** (a
     Statuspage site just needs the name + base URL), no rebuild required.

   Then skip to step 6 to verify.

3. **Otherwise, scaffold a new adapter.** First `curl` the real response to learn
   its JSON shape — that shape drives `parse`. Create `adapters/<id>/` with:
   - `adapter.json` — `{ "id", "name", "description", "entry": "dist/index.js" }`
   - `package.json` — copy from `adapters/aws/package.json`, change the name; keep
     the `@statusbar/adapter-sdk` workspace dependency.
   - `tsconfig.json` — copy from `adapters/aws/tsconfig.json`.
   - `src/index.ts` — the adapter (see below).
   Add the package to `adapters/pnpm-workspace.yaml`.

4. **Write `src/index.ts`.** Start from the template in `adapters/README.md`.
   - Map the source's states to `StatusLevel` (`operational | minor | major | unknown`).
   - Emit one `issue` per active problem (`{ component?, title, level? }`); the app
     de-duplicates by title, so per-component issues are fine.
   - Return `{ level, detail, issues }`.
   - Add a `suggestedSites` entry so it appears in Settings' Add menu.
   - Base every mapping on the **actual** response you fetched, not assumptions.

5. **Build and type-check:**
   ```sh
   make adapters
   pnpm -C adapters typecheck
   ```

   Then test `parse` against the real response (pure function, so this is easy):
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
   The site should appear with the right shape/detail (add it to config or via
   Settings first, using the adapter id).

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
