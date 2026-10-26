---
"statusbar": patch
---

chore: give the installer the usual drag-to-Applications layout

The .dmg now opens as a fixed-size window with the app on the left, the Applications shortcut on the right, and an arrow between them, instead of Finder's default alphabetical icon grid. It's laid out with `dmgbuild`, which writes the layout directly rather than scripting Finder, so it works on CI.
