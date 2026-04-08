import os
import plistlib


application = defines["app"]  # noqa: F821
appname = os.path.basename(application)
background_image = defines["background"]  # noqa: F821
background_extension = os.path.splitext(background_image)[1]
background_name = ".background" + background_extension
volume_name = defines.get("volume_name", appname)  # noqa: F821


def icon_from_app(app_path):
    plist_path = os.path.join(app_path, "Contents", "Info.plist")
    with open(plist_path, "rb") as handle:
        plist = plistlib.load(handle)

    icon_name = plist.get("CFBundleIconFile", "AppIcon")
    icon_root, icon_ext = os.path.splitext(icon_name)
    if not icon_ext:
        icon_ext = ".icns"

    return os.path.join(app_path, "Contents", "Resources", icon_root + icon_ext)


format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
badge_icon = icon_from_app(application)
hide = [background_name]

background = background_image
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
window_rect = ((120, 120), (720, 440))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = "auto"
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 96
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 16
icon_size = 128

icon_locations = {
    appname: (180, 255),
    "Applications": (540, 255),
}
