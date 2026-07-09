---
'statusbar': minor
---

Demote lingering low-impact issues that have gone quiet. Non-major issues whose source hasn't posted an update within a configurable window (`staleIssueThresholdHours`, default 72h) are moved into a per-site "low-priority" submenu and no longer drive the menubar icon, so a weeks-old minor incident stops keeping the icon lit. Threaded incident `updatedAt` through the adapter SDK, the Statuspage adapter, and the core models to detect staleness; toggle with the new `demoteStaleIssues` config option.
