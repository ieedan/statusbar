# statusbar

## 0.2.2

### Patch Changes

- [#5](https://github.com/ieedan/statusbar/pull/5) [`f024e39`](https://github.com/ieedan/statusbar/commit/f024e39236388bbef20b2f3aa44067ebff1722ef) Thanks [@ieedan](https://github.com/ieedan)! - fix: scheduled maintenance no longer lights the menubar

  A Statuspage component sitting in `under_maintenance` — or a page whose overall
  indicator is `maintenance` — mapped to `minor`, so planned work turned the
  menubar icon into a warning triangle. Maintenance is work the operator scheduled,
  not something going wrong, so it now maps to `operational`: it's still listed
  under the site so you can see it's happening, but only unplanned trouble raises
  the icon. A maintenance window alongside a real degradation still warns, on the
  strength of the degradation.

- [#5](https://github.com/ieedan/statusbar/pull/5) [`f024e39`](https://github.com/ieedan/statusbar/commit/f024e39236388bbef20b2f3aa44067ebff1722ef) Thanks [@ieedan](https://github.com/ieedan)! - fix: stop large Statuspage sites reading as a permanent outage

  Cloudflare's rebuilt status page reports "All systems operational" while the
  Statuspage API it still serves rolls its ~340 edge locations into the top-level
  indicator — a handful are always rerouted or under maintenance, so the site (and
  with it the menubar icon) sat on orange indefinitely, explained only by two
  useless rows reading "Partial Outage" and "Under Maintenance".

  The Statuspage adapter now passes each component's `updated_at` through as the
  issue's `updatedAt`, so degraded components are aged like every other issue and
  standing infrastructure noise is demoted into the low-priority submenu instead of
  driving the icon. A component that degrades now still surfaces immediately.

  It also skips component _group_ headers whose children are in the same payload —
  a group's status is a rollup of those children, so emitting both reported the
  same degradation twice ("Africa" alongside each of its cities).

- [#5](https://github.com/ieedan/statusbar/pull/5) [`172e871`](https://github.com/ieedan/statusbar/commit/172e87129fad35a73b6d8715bd671fa4ecafba6f) Thanks [@ieedan](https://github.com/ieedan)! - chore: sign and notarize release builds

  Releases are now signed with a Developer ID certificate and notarized by Apple, so the app opens without the `xattr -cr` workaround.

## 0.2.1

### Patch Changes

- [`362c5d5`](https://github.com/ieedan/statusbar/commit/362c5d5e738e9a91e279530e581d600bfb084d3b) Thanks [@ieedan](https://github.com/ieedan)! - fix: show correct color for status

- [`b5dbc3d`](https://github.com/ieedan/statusbar/commit/b5dbc3d49f9042025ec59375bc2eb7a17c59c28b) Thanks [@ieedan](https://github.com/ieedan)! - fix: better handle overall status and site statuses

## 0.2.0

### Minor Changes

- [`591e021`](https://github.com/ieedan/statusbar/commit/591e021f96f722ef5764032e37ae6ffb2b0aa1fd) Thanks [@ieedan](https://github.com/ieedan)! - Demote lingering low-impact issues that have gone quiet. Non-major issues whose source hasn't posted an update within a configurable window (`staleIssueThresholdHours`, default 72h) are moved into a per-site "low-priority" submenu and no longer drive the menubar icon, so a weeks-old minor incident stops keeping the icon lit. Threaded incident `updatedAt` through the adapter SDK, the Statuspage adapter, and the core models to detect staleness; toggle with the new `demoteStaleIssues` config option.

### Patch Changes

- [`ba18d68`](https://github.com/ieedan/statusbar/commit/ba18d68713d556e39808b7e5c0d1408f0ac62fca) Thanks [@ieedan](https://github.com/ieedan)! - Render the menubar status icon as a template image so macOS tints it to match the menubar's text color (white on dark, black on light), matching the other menubar items instead of showing as a colored shape. Severity is still legible from the icon's shape. The colored icons in the dropdown menu are unchanged.

## 0.1.2

### Patch Changes

- [`d215714`](https://github.com/ieedan/status-bar/commit/d215714bb14f07ad577df71476a24eff29d7ef5c) Thanks [@ieedan](https://github.com/ieedan)! - chore: fix release signing

## 0.1.1

### Patch Changes

- [`e63c873`](https://github.com/ieedan/status-bar/commit/e63c8738d430d1555a5b6163d75069951c2c5897) Thanks [@ieedan](https://github.com/ieedan)! - chore: automated releases
