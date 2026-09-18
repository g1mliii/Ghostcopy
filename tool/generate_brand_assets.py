#!/usr/bin/env python3
"""Regenerate every icon in the repo from assets/brand/*.svg.

    DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 tool/generate_brand_assets.py

Needs `brew install cairo` and `pip3 install cairosvg pillow`. Cairo is a
system library, so the DYLD_LIBRARY_PATH is how Python's ctypes finds it on
Homebrew installs.

Everything here is derived, so the safe way to change the logo is to change a
master and re-run. Hand-editing a PNG leaves it to be silently overwritten.
"""

import io
import os
import sys

try:
    import cairosvg
except OSError as exc:  # pragma: no cover - environment problem, not logic
    sys.exit(f"cairosvg could not load Cairo: {exc}\n"
             "Try: DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 "
             "tool/generate_brand_assets.py")
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "assets", "brand")

# GhostColors.background and GhostColors.primary. Kept in step with
# lib/ui/theme/colors.dart by hand - there is no way to import Dart here.
BACKGROUND = (0x0F, 0x0F, 0x13)
PRIMARY = (0x66, 0x70, 0xFF)
SURFACE = (0x19, 0x19, 0x1F)  # card colour the email templates sit the logo on

written = []


def render(master: str, px: int) -> Image.Image:
    """Rasterise a master SVG at px by px, alpha preserved."""
    png = cairosvg.svg2png(
        url=os.path.join(BRAND, master), output_width=px, output_height=px
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def save(img: Image.Image, *parts: str) -> None:
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    written.append(os.path.relpath(path, ROOT))


def tile(px: int, *, inset: float = 0.72, radius: float | None = None,
         bg=PRIMARY, opaque: bool = True) -> Image.Image:
    """The mark centred on a filled tile - what an app icon looks like.

    `inset` is the share of the tile the mark occupies. 0.72 leaves the margin
    Apple's grid expects; filling the square edge to edge reads as cramped
    beside other icons.

    `opaque` matters: an iOS app icon with any alpha at all is rejected at
    upload, so the tile is flattened rather than merely looking solid.
    """
    canvas = Image.new("RGBA", (px, px), bg + (255,))
    if radius is not None:
        mask = rounded_mask(px, radius)
        canvas.putalpha(mask)

    mark_px = max(1, int(px * inset))
    mark = render("logo-white.svg", mark_px)
    canvas.alpha_composite(mark, ((px - mark_px) // 2, (px - mark_px) // 2))
    return canvas.convert("RGB") if opaque else canvas


def rounded_mask(px: int, radius: float) -> Image.Image:
    from PIL import ImageDraw

    # 4x supersample, because a rounded corner drawn at 16px is visibly jagged
    scale = 4
    mask = Image.new("L", (px * scale, px * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, px * scale - 1, px * scale - 1),
        radius=int(radius * px * scale),
        fill=255,
    )
    return mask.resize((px, px), Image.LANCZOS)


def on_transparent(px: int, master: str = "logo-white.svg") -> Image.Image:
    return render(master, px)


def ios_app_icon() -> None:
    """iOS: opaque, square, no rounded corners - the OS masks them itself."""
    for name, px in [
        ("Icon-App-20x20@1x", 20), ("Icon-App-20x20@2x", 40), ("Icon-App-20x20@3x", 60),
        ("Icon-App-29x29@1x", 29), ("Icon-App-29x29@2x", 58), ("Icon-App-29x29@3x", 87),
        ("Icon-App-40x40@1x", 40), ("Icon-App-40x40@2x", 80), ("Icon-App-40x40@3x", 120),
        ("Icon-App-60x60@2x", 120), ("Icon-App-60x60@3x", 180),
        ("Icon-App-76x76@1x", 76), ("Icon-App-76x76@2x", 152),
        ("Icon-App-83.5x83.5@2x", 167),
        ("Icon-App-1024x1024@1x", 1024),
    ]:
        save(tile(px), "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset",
             f"{name}.png")


def ios_launch() -> None:
    """Launch screen: the mark alone on transparent, over the dark storyboard."""
    for name, px in (("LaunchImage", 120), ("LaunchImage@2x", 240),
                     ("LaunchImage@3x", 360)):
        save(on_transparent(px), "ios", "Runner", "Assets.xcassets",
             "LaunchImage.imageset", f"{name}.png")


def macos_app_icon() -> None:
    """macOS draws its own icons unmasked, so the rounded corner is ours."""
    for px in (16, 32, 64, 128, 256, 512, 1024):
        save(tile(px, radius=0.225, opaque=False),
             "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset",
             f"app_icon_{px}.png")


def android_icons() -> None:
    densities = (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3),
                 ("xxxhdpi", 4))
    for suffix, scale in densities:
        save(tile(int(48 * scale)), "android", "app", "src", "main", "res",
             f"mipmap-{suffix}", "ic_launcher.png")
        save(on_transparent(int(120 * scale)), "android", "app", "src", "main",
             "res", f"mipmap-{suffix}", "launch_image.png")
        # Notification icon: Android masks this to a single colour, so it has
        # to be a flat white silhouette on transparent. Anything with colour
        # or detail arrives as a grey blob.
        save(on_transparent(int(24 * scale)), "android", "app", "src", "main",
             "res", f"drawable-{suffix}", "ic_stat_ghostcopy.png")


def android_adaptive_icon() -> None:
    """Adaptive icon (API 26+) and the themed icon (API 33+).

    Without this, a launcher letterboxes the legacy square icon inside its own
    shape, so it draws visibly smaller than every icon beside it.

    The canvas is 108dp but only the centre 66dp is guaranteed to survive
    masking - a launcher may crop to a circle, a squircle or a teardrop, and
    may shift the layers for parallax. So the mark is inset to sit well inside
    that safe zone rather than filling the square.

    The monochrome layer is what Android 13's themed icons tint, and it must
    be the silhouette alone: the system paints it a single colour drawn from
    the wallpaper, so any tile or colour baked in comes out as a solid blob.
    """
    for suffix, scale in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2),
                          ("xxhdpi", 3), ("xxxhdpi", 4)):
        px = int(108 * scale)
        # 0.50 of 108dp = 54dp, comfortably inside the 66dp safe zone.
        layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        mark_px = max(1, int(px * 0.50))
        mark = render("logo-white.svg", mark_px)
        layer.alpha_composite(mark, ((px - mark_px) // 2, (px - mark_px) // 2))
        save(layer, "android", "app", "src", "main", "res",
             f"mipmap-{suffix}", "ic_launcher_foreground.png")
        save(layer, "android", "app", "src", "main", "res",
             f"drawable-{suffix}", "ic_launcher_monochrome.png")

    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by tool/generate_brand_assets.py -->\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ghost_icon_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
        '</adaptive-icon>\n'
    )
    # No ic_launcher_round.xml. android:roundIcon exists for API 25's round
    # masks and the manifest does not declare one; an adaptive icon already
    # answers a round mask, so a second file would never be read.
    for name in ("ic_launcher.xml",):
        path = os.path.join(ROOT, "android", "app", "src", "main", "res",
                            "mipmap-anydpi-v26", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(xml)
        written.append(os.path.relpath(path, ROOT))


def tray_icons() -> None:
    # macOS menu bar wants a template image: black on transparent, which the
    # OS inverts for dark menu bars. White here vanishes on a light one.
    save(on_transparent(44, "logo-black.svg"), "assets", "icons",
         "tray_icon_macos.png")
    save(tile(64, radius=0.2, opaque=False), "assets", "icons", "tray_icon.png")
    save(tile(24, radius=0.2, opaque=False), "assets", "icons",
         "tray_icon_linux.png")


def flutter_assets() -> None:
    """The in-app header tints this white at runtime, so ship it white."""
    save(on_transparent(1024), "assets", "icons", "logo_white.png")
    save(on_transparent(1024, "logo-black.svg"), "assets", "icons",
         "logo_dark.png")
    save(tile(1024), "assets", "icons", "app_icon.png")


def flutter_web() -> None:
    save(tile(192), "web", "icons", "Icon-192.png")
    save(tile(512), "web", "icons", "Icon-512.png")
    # Maskable icons are cropped to a circle by the launcher, so the mark sits
    # inside the safe zone rather than filling the square.
    save(tile(192, inset=0.52), "web", "icons", "Icon-maskable-192.png")
    save(tile(512, inset=0.52), "web", "icons", "Icon-maskable-512.png")
    save(tile(32), "web", "favicon.png")


def website() -> None:
    for base in ("website", os.path.join("website", "dist")):
        save(tile(180, radius=0.22, opaque=False), base, "icons",
             "apple-touch-icon.png")
        save(tile(512), base, "icons", "icon-512.png")
        save(tile(32), base, "icons", "favicon-32.png")
        save(tile(16), base, "icons", "favicon-16.png")
        # The site's primary favicon: <link rel="icon" href="/icons/ghost.svg">
        with open(os.path.join(BRAND, "logo-white.svg")) as fh:
            svg = fh.read()
        tinted = svg.replace(
            "<path",
            f'<rect x="210.9" y="101.3" width="1655.9" height="1655.9" rx="240" '
            f'fill="#{PRIMARY[0]:02X}{PRIMARY[1]:02X}{PRIMARY[2]:02X}"/>\n<path',
            1,
        )
        path = os.path.join(ROOT, base, "icons", "ghost.svg")
        with open(path, "w") as fh:
            fh.write(tinted)
        written.append(os.path.relpath(path, ROOT))


def email_logo() -> None:
    """A hosted logo for the Supabase auth emails.

    Email cannot reference a local asset, so this has to live at a public URL -
    https://ghostcopy.app/icons/email-logo.png, served by the same site as the
    favicons. Written at 2x the display size because mail clients do not do
    srcset and the templates set an explicit width.

    PNG, not SVG: Gmail strips SVG entirely.

    Flattened onto the card colour rather than left transparent. Outlook's Word
    renderer composites PNG alpha against white, which would turn the rounded
    corners into white wedges on the dark card; baking #19191F in makes them
    disappear against it in every client instead.
    """
    card = Image.new("RGBA", (128, 128), SURFACE + (255,))
    card.alpha_composite(tile(128, radius=0.22, opaque=False))
    for base in ("website", os.path.join("website", "dist")):
        save(card.convert("RGB"), base, "icons", "email-logo.png")


def favicon_ico() -> None:
    """Multi-resolution .ico for Windows and the website."""
    sizes = [16, 24, 32, 48, 64, 128, 256]
    frames = [tile(s) for s in sizes]
    for parts in (("website", "icons", "favicon.ico"),
                  ("website", "dist", "icons", "favicon.ico"),
                  ("windows", "runner", "resources", "app_icon.ico"),
                  ("installer", "ghostcopy.ico")):
        path = os.path.join(ROOT, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        frames[-1].save(path, format="ICO",
                        sizes=[(s, s) for s in sizes])
        written.append(os.path.relpath(path, ROOT))


if __name__ == "__main__":
    ios_app_icon()
    ios_launch()
    macos_app_icon()
    android_icons()
    android_adaptive_icon()
    tray_icons()
    flutter_assets()
    flutter_web()
    website()
    email_logo()
    favicon_ico()
    print(f"wrote {len(written)} files")
    for w in sorted(written):
        print("   ", w)
