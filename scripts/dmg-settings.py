# dmgbuild settings for Rune's disk image (https://github.com/dmgbuild/dmgbuild, MIT).
# Invoked by scripts/make-dmg.sh with -D app=<Rune.app> -D background=<tiff> -D icon=<icns>.
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
size = None

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821

# Window: 660×400 content, positioned near the top-left of the screen.
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
label_pos = "bottom"
icon_locations = {
    app_name: (165, 205),
    "Applications": (495, 205),
}
