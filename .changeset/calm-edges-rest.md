---
"statusbar": patch
---

fix: stop huge Statuspage sites reading as an outage when nothing is down

Cloudflare lists ~340 edge locations beside its ~130 services, and a few dozen are always in `major_outage` or `degraded_performance`. Statuspage rolls those into the top-level indicator, so the menubar showed "Partial System Outage" while Cloudflare's own page said "No known service issues". Aging the issues couldn't fix it: major outages never age out, and plenty of locations had changed state within the last 72 hours.

With no active incident, a page listing 100 or more components now reads operational, and its non-operational components are summarised in a single informational row instead of setting the site's level. Active incidents still drive the level exactly as before, and smaller pages are unchanged.
