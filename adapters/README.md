# Adapters

An **adapter** teaches StatusBar how to read one *kind* of status source — an
Atlassian Statuspage, the AWS Health feed, or anything you can parse from an HTTP
response. Adapters are small TypeScript modules. You can write your own and drop
them in without touching the app.

- [`sdk/`](sdk) — `@statusbar/adapter-sdk`: the types and `defineAdapter` helper.
- [`statuspage/`](statuspage) — reads any Atlassian Statuspage.
- [`aws/`](aws) — reads the AWS Health current-events feed.

## The model: adapters are pure parsers

The **app does all networking.** Your adapter only:

1. `endpoint(baseURL)` — given a site's configured base URL, return the URL to fetch.
2. `parse(body)` — turn the fetched response body (a string) into a normalized status.

That's it. No `fetch`, no async, no secrets — `parse` is a pure function of a
string, which makes adapters trivial to test and safe to install. Adapters run in
an isolated JavaScriptCore sandbox with no network or filesystem access.

## Anatomy

```
my-adapter/
  adapter.json        # { "id", "name", "description", "entry": "dist/index.js" }
  package.json        # depends on @statusbar/adapter-sdk
  src/index.ts        # your code — calls defineAdapter(...)
  dist/index.js       # built bundle the app loads (produced by the build)
```

### `src/index.ts`

```ts
import { defineAdapter, type StatusLevel } from "@statusbar/adapter-sdk";

export default defineAdapter({
  id: "example",
  name: "Example",
  description: "Reads status from example.com's status API.",

  // Build the URL to fetch from the site's configured base URL.
  endpoint: (baseURL) => baseURL.replace(/\/+$/, "") + "/status.json",

  // Turn the response body into a normalized status.
  parse: (body) => {
    const data = JSON.parse(body);
    const level: StatusLevel = data.ok ? "operational" : "major";
    return {
      level,
      detail: data.message ?? "Unknown",
      issues: (data.incidents ?? []).map((i: any) => ({
        component: i.area,
        title: i.name,
      })),
    };
  },

  // Optional: sites offered in Settings' "Add service" menu.
  suggestedSites: [{ id: "example", name: "Example", url: "https://example.com" }],
});
```

## The contract

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `string` | Stable, unique. Referenced by each site's `adapterID`. |
| `name` | `string` | Shown in Settings. |
| `description?` | `string` | One line. |
| `endpoint(baseURL)` | `(string) => string` | The URL to fetch. Return `baseURL` for a fixed feed. |
| `parse(body, ctx)` | `(string, {baseURL}) => StatusResult` | Pure. Must not throw on the happy path. |
| `suggestedSites?` | `SuggestedSite[]` | `{ id, name, url }[]` catalog contributions. |

`StatusResult` is `{ level, detail, issues? }`, where `level` is one of
`"operational" | "minor" | "major" | "unknown"` and each issue is
`{ component?, title, level? }`. Issues that share a `title` are automatically
de-duplicated and capped in the menu, so it's fine to emit one per component.

The app maps `level` to the menubar shape: operational → circle, minor →
triangle, major → rounded square, unknown → dashed circle.

## Build

```sh
make adapters          # from the repo root — installs deps + builds every adapter
# or:
cd adapters && pnpm install && pnpm build
```

The build discovers every directory with an `adapter.json` and bundles its
`src/index.ts` into `dist/index.js` (a self-contained IIFE). Type-check with
`pnpm -C adapters typecheck`.

## Test

Because `parse` is pure, you can exercise it directly:

```sh
node -e "require('./dist/index.js'); \
  console.log(JSON.stringify(globalThis.__STATUSBAR_ADAPTER__.parse('<body>', {baseURL:''})))"
```

Or check every configured site end-to-end through the real runtime:

```sh
make check
```

## No build required — plain JavaScript works

The TypeScript SDK is for convenience (types + autocomplete). At runtime an
adapter is just JavaScript, and the app provides `defineAdapter` as a global, so
you can hand-write a **single `.js` file with no toolchain at all**:

```js
// my-adapter.js — no imports, no build.
defineAdapter({
  id: "example",
  name: "Example",
  endpoint: (baseURL) => baseURL + "/status.json",
  parse: (body) => {
    const d = JSON.parse(body);
    return { level: d.ok ? "operational" : "major", detail: d.message };
  },
  suggestedSites: [{ id: "example", name: "Example", url: "https://example.com" }],
});
```

## Installing (for end users)

You do **not** need to build from source or use the terminal. In the app:

1. **Settings… (⌘,) → Adapters… → Install Adapter…** and pick a `.js` file (or an
   adapter folder). The app validates it, copies it in, and loads it immediately.
2. Or **Adapters… → Reveal Adapters Folder** and drop a `.js` file into:
   ```
   ~/Library/Application Support/StatusBar/adapters/
   ```
   then **Reload Config & Refresh**.

Either way, the adapter's `suggestedSites` appear in the **+** (Add service) menu,
and any site using its `id` as `adapterID` becomes readable. User adapters
override built-in ones with the same `id`. Check what's loaded with
`StatusBar --adapters`.

## Add a site

Run the `/add-site` skill — it reuses an existing adapter when one already covers
the site, and only scaffolds a new adapter when nothing can read the source. Give
it the site in plain language:

```
/add-site Add "GitLab" to my statusbar
```

To scaffold by hand instead, copy an existing adapter to generate a starter. For a
quick one-off, a single plain `.js` file (above) is enough.
