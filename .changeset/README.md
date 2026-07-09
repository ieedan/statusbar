# Changesets

This folder is managed by [changesets](https://github.com/changesets/changesets).

Every user-facing change should ship with a changeset. To add one, run:

```
pnpm changeset
```

Pick a bump type (patch / minor / major) and write a short summary — it becomes
the changelog entry. Changesets accumulate here until a release. On push to
`main`, CI opens (or updates) a **Version Packages** PR that consumes every
pending changeset, bumps the version in `package.json`, and writes `CHANGELOG.md`.
Merging that PR builds the macOS app and cuts the GitHub Release.
