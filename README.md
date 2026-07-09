# statusbar

See if any of the services you use every day are down, live in your status bar.

<img width="790" height="778" alt="CleanShot 2026-07-09 at 13 46 13@2x" src="https://github.com/user-attachments/assets/1af21ddf-7ab6-4ac6-ba1e-da68f7a0464a" />

## Install

1. Download the latest `StatusBar-<version>-macos-arm64.zip` from the [Releases](https://github.com/ieedan/status-bar/releases) page.
2. Unzip it and drag `StatusBar.app` into `/Applications`.
3. Because I'm not forking over $100 a year to apple right now the app isn't signed. So just run this to take it out of quarantine and everything will work.

   ```sh
   xattr -cr "/Applications/StatusBar.app"
   ```

   > You will need to do this for every new release

## Adding other sites

Support for a site is a small **adapter**. Most sites are already covered by a
built-in adapter, so adding one is usually just a name + URL in **Settings → Add
service** (or **Add Custom…** for any Atlassian Statuspage site).

If you want your agent to do this part for you, just add the /add-site skill and tell your agent:
```
/add-site Add "GitLab" to my statusbar
```
