# statusbar

See if any of the services you use every day are down, live in your status bar.

<img width="790" height="778" alt="CleanShot 2026-07-09 at 13 46 13@2x" src="https://github.com/user-attachments/assets/1af21ddf-7ab6-4ac6-ba1e-da68f7a0464a" />

## Install

1. Download the latest `StatusBar-<version>-macos-arm64.dmg` from the [Releases](https://github.com/ieedan/statusbar/releases) page.
2. Open it and drag `StatusBar.app` onto the `Applications` shortcut, then open it from there. Releases are signed with a Developer ID certificate and notarized by Apple, so Gatekeeper opens it without any extra steps.

## Adding other sites

Support for a site is a small **adapter**. Most sites are already covered by a
built-in adapter, so adding one is usually just a name + URL in **Settings → Add
service** (or **Add Custom…** for any Atlassian Statuspage site).

If you want your agent to do this part for you, just add the /add-site skill and tell your agent:
```
/add-site Add "GitLab" to my statusbar
```

## Development

```sh
pnpm install
pnpm setup:dev
```

This installs the adapter dependencies and builds everything. Then `make run` starts the app.

## Releasing

Releases are signed and notarized by CI. Run this once to set the Apple secrets on the GitHub repo:

```sh
pnpm setup:prod
```
