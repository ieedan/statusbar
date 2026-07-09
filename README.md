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
| [`packages/StatusCore`](packages/StatusCore) | UI-agnostic library: models, status providers, the refresh engine, and config. Fully unit-tested. |
| [`apps/StatusBar`](apps/StatusBar) | The AppKit menubar agent (`LSUIElement`), depending on `StatusCore`. |

Keeping the logic in `StatusCore` means the network/parsing behavior is testable
without launching a UI, and a second front-end (CLI, SwiftUI, etc.) could reuse it.

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

## How status is determined

- **Statuspage** (`/api/v2/summary.json`) exposes an overall `indicator` —
  `none` → green, `minor`/`maintenance` → orange, `major`/`critical` → red — plus
  the active `incidents` and their affected `components`, which become the
  per-site detail lines. If an incident-free page still reports degraded
  components, those are shown instead.
- **AWS** returns a list of active events (numeric severity `1`/`2` → orange,
  `3` → red), each surfaced as a detail line; an empty list means all clear.
- The menubar icon reflects the **worst** level across all monitored sites.
