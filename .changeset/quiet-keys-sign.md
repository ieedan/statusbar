---
"statusbar": patch
---

chore: sign and notarize release builds

Releases are now signed with a Developer ID certificate and notarized by Apple, so the app opens without the `xattr -cr` workaround.
