# Layout for the installer .dmg, read by `dmgbuild` (see scripts/build-dmg.sh).
#
# Matches the usual drag-to-Applications look: a 540×380 window with no toolbar or
# sidebar, the app on the left, the Applications shortcut on the right, and an arrow
# between them. The background is rendered by scripts/make-dmg-background.swift;
# keep the window size and icon positions in step with it.
import os

# Passed in with `dmgbuild -D app=<path to StatusBar.app> -D root=<repo root>`.
app = defines["app"]  # noqa: F821  (injected by dmgbuild)
root = defines["root"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}

# The disk image's own icon in Finder and on the desktop.
icon = os.path.join(root, "assets", "AppIcon.icns")
background = os.path.join(root, "assets", "dmg-background.tiff")

window_rect = ((200, 120), (540, 380))
icon_size = 80
text_size = 12
icon_locations = {
    app_name: (130, 220),
    "Applications": (410, 220),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
label_pos = "bottom"
