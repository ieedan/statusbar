---
"statusbar": patch
---

fix: stop large Statuspage sites reading as a permanent outage

Cloudflare's rebuilt status page reports "All systems operational" while the
Statuspage API it still serves rolls its ~340 edge locations into the top-level
indicator — a handful are always rerouted or under maintenance, so the site (and
with it the menubar icon) sat on orange indefinitely, explained only by two
useless rows reading "Partial Outage" and "Under Maintenance".

The Statuspage adapter now passes each component's `updated_at` through as the
issue's `updatedAt`, so degraded components are aged like every other issue and
standing infrastructure noise is demoted into the low-priority submenu instead of
driving the icon. A component that degrades now still surfaces immediately.

It also skips component *group* headers whose children are in the same payload —
a group's status is a rollup of those children, so emitting both reported the
same degradation twice ("Africa" alongside each of its cities).
