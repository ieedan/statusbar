# status-bar

> Is it me? Or is it GitHub again? Find out here.

A native macOS menubar app that watches the status of the sites you depend on and
shows a single at-a-glance indicator. Severity is encoded by **shape as well as
color**, so it's legible without relying on color alone:

- 🟥 **red rounded-square** — a major outage on at least one site
- 🔺 **orange triangle** — a minor/partial incident
- ⚪️ **gray circle** — all systems operational
- ⚪️ **dashed gray circle** — unknown / not yet checked

Click the menubar icon for a per-site breakdown. Each affected site lists the
specific incidents beneath it (e.g. `Actions — Delays starting Actions runs`),
and clicking a site opens its full status page.

## Default sites

Vercel · GitHub · Cloudflare · AWS · Anthropic · OpenAI · PlanetScale ·
Supabase · Convex · Discord

The list is fully configurable — see [Configuration](#configuration).

## Layout

This is a Swift monorepo with two packages:

| Path | What it is |
| --- | --- |
| [`packages/StatusCore`](packages/StatusCore) | UI-agnostic library: models, the adapter runtime (JavaScriptCore), refresh engine, and config. Fully unit-tested. |
| [`apps/StatusBar`](apps/StatusBar) | The AppKit menubar agent (`LSUIElement`), depending on `StatusCore`. |
| [`adapters/`](adapters) | TypeScript **adapters** — pluggable per-source status parsers, plus the SDK. |

Keeping the logic in `StatusCore` means behavior is testable without launching a
UI. How to read each site's status lives in **adapters** — small TypeScript
plugins the app runs in JavaScriptCore — so adding support for a new site doesn't
require touching Swift. See [adapters/README.md](adapters/README.md).

## Develop

Requires macOS 13+ and a Swift 6 toolchain (ships with Xcode 16+).

```sh
make test    # run the StatusCore test suite
make run     # run the menubar app from source (Ctrl-C to stop)
make app     # package dist/Site Status.app
make build   # compile both packages
```

A headless diagnostic mode checks every site once and prints the result:

```sh
cd apps/StatusBar && swift run StatusBar --check
```

```
Overall: 🔴 major
  ⚪️ Vercel       All Systems Operational
  🟠 GitHub       Minor Service Outage
  🟠 Cloudflare   Minor Service Outage
  🔴 AWS          Increased Error Rates
  ⚪️ Anthropic    All Systems Operational
  🟠 OpenAI       Partial System Degradation
```

## Install

```sh
make install          # builds and copies Site Status.app to /Applications
open "/Applications/Site Status.app"
```

To start it automatically on login, open **Settings… (⌘,)** and tick
**Launch at login** (bottom-right). This uses `SMAppService`, so it shows up
under **System Settings → General → Login Items** and can be turned off there too.

## Configuration

The easiest way is the **Settings…** window (menubar → Settings…, or ⌘,):

- **Add** a service from the built-in catalog, or **Add Custom…** with any
  Statuspage URL.
- **Drag rows** to reorder how services appear in the menu.
- **Right-click a row** to Remove, Enable/Disable, or open its status page (or
  use the − button / the enable checkbox).

Every change is saved immediately and the menubar refreshes. Reordering and
removal live here rather than in the dropdown because the menubar dropdown is an
`NSMenu`, which can't host drag-and-drop or per-row context menus.

Everything is also editable as JSON at:

```
~/Library/Application Support/StatusBar/config.json
```

After editing by hand, run **Reload Config & Refresh**. Each site has:

```json
{
  "id": "github",
  "name": "GitHub",
  "kind": "statuspage",
  "url": "https://www.githubstatus.com",
  "enabled": true
}
```

- `kind: "statuspage"` — any [Atlassian Statuspage](https://www.atlassian.com/software/statuspage)
  site. `url` is the page's base URL; the app reads `…/api/v2/status.json`. This
  covers most large providers, so adding a new one is usually just a name + URL.
- `kind: "awsHealth"` — the AWS Health current-events feed (AWS doesn't use
  Statuspage). `url` should be `https://health.aws.amazon.com/public/currentevents`.

`refreshIntervalSeconds` controls how often every site is re-checked (minimum 15s).

## Plugins (adapters)

Support for a new site is a small **adapter** — you don't need to rebuild the app.
No terminal required:

- **Install:** Settings… → **Adapters… → Install Adapter…**, pick a `.js` file
  (or drop one into **Reveal Adapters Folder**). It loads immediately and its
  suggested sites appear in the **+** menu.
- **Author:** an adapter can be a single hand-written `.js` file — no TypeScript,
  no build. See [adapters/README.md](adapters/README.md), or run
  [`/create-adapter`](.claude/skills/create-adapter/SKILL.md).

## How status is determined

Each site names an **adapter** that knows how to read its status. Adapters are
pure TypeScript parsers ([adapters/](adapters)): the app fetches, the adapter
normalizes the response into a level + issues. Two ship built-in:

- **statuspage** — reads any Atlassian Statuspage `/api/v2/summary.json`: the
  overall `indicator` (`none` → gray, `minor` → orange, `major`/`critical` → red)
  plus active `incidents`/`components`, which become the per-site detail lines.
- **aws** — reads the AWS Health current-events feed (numeric severity
  `1`/`2` → orange, `3` → red).

Each adapter also contributes `suggestedSites`, which populate Settings' **Add
service** menu — so installing an adapter adds its sites. Write your own with the
[`/create-adapter`](.claude/skills/create-adapter/SKILL.md) skill.

The menubar icon reflects the **worst** level across all monitored sites.
