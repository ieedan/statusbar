---
"statusbar": patch
---

fix: scheduled maintenance no longer lights the menubar

A Statuspage component sitting in `under_maintenance` — or a page whose overall
indicator is `maintenance` — mapped to `minor`, so planned work turned the
menubar icon into a warning triangle. Maintenance is work the operator scheduled,
not something going wrong, so it now maps to `operational`: it's still listed
under the site so you can see it's happening, but only unplanned trouble raises
the icon. A maintenance window alongside a real degradation still warns, on the
strength of the degradation.
