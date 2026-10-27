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
import struct
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "assets", "brand")

# GhostColors.background and GhostColors.primary. Kept in step with
# lib/ui/theme/colors.dart by hand - there is no way to import Dart here.
BACKGROUND = (0x0F, 0x0F, 0x13)
PRIMARY = (0x66, 0x70, 0xFF)
SURFACE = (0x19, 0x19, 0x1F)  # card colour the email templates sit the logo on
WHITE = (0xFF, 0xFF, 0xFF)

# The icon in its two appearances. Always an indigo ghost; the tile behind it
# is white in light mode and near-black in dark, and the eyes are cut out, so
# they show the tile - white eyes on white, black on black.
#
# It used to be a white ghost on an indigo tile, which next to Discord's white
# mark on a blurple tile was the same icon at a glance.
LIGHT_TILE = WHITE
DARK_TILE = BACKGROUND

# The corner radius for every platform that does not mask icons itself -
# macOS, Windows, and the website's touch icon. iOS is masked by the OS and
# Android has its own adaptive shape, so neither uses this.
MASK_RADIUS = 0.225

written = []


def render(master: str, px: int) -> Image.Image:
    """Rasterise a master SVG at px by px, alpha preserved.

    Cairo is imported here, not at module scope, so the pure-Pillow helpers in
    this file - rounded_mask, write_ico - can be imported and used on a machine
    without it. Windows ships no libcairo-2.dll, and reusing these rather than
    restating their arithmetic somewhere else is the whole point of having one
    generator.
    """
    try:
        import cairosvg
    except OSError as exc:  # pragma: no cover - environment, not logic
        sys.exit(f"cairosvg could not load Cairo: {exc}\n"
                 "Try: DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 "
                 "tool/generate_brand_assets.py")
    png = cairosvg.svg2png(
        url=os.path.join(BRAND, master), output_width=px, output_height=px
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def save(img: Image.Image, *parts: str) -> None:
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    written.append(os.path.relpath(path, ROOT))


def mark(px: int, color=PRIMARY) -> Image.Image:
    """The ghost at px, filled with color, on transparency.

    Only the master's alpha is kept, so the eyes - holes in the path - stay
    holes and show whatever the mark is drawn over.
    """
    alpha = render("logo-white.svg", px).getchannel("A")
    out = Image.new("RGBA", (px, px), color + (255,))
    out.putalpha(alpha)
    return out


def tile(px: int, *, inset: float = 0.92, radius: float | None = None,
         bg=LIGHT_TILE, fg=PRIMARY, opaque: bool = True) -> Image.Image:
    """The mark centred on a filled tile - what an app icon looks like.

    `inset` is the share of the tile given to the master's square viewBox,
    not to the ghost itself. The master pads the tall, narrow ghost inside
    that square, so 0.72 - chosen as if the ghost filled it - drew the ghost
    at 57% of the icon's height and a third of its width, visibly smaller
    than the marks on neighbouring icons. 0.92 puts it at about 73% tall,
    which matches their weight and still leaves clear space top and bottom.

    `opaque` matters: an iOS app icon with any alpha at all is rejected at
    upload, so the tile is flattened rather than merely looking solid.
    """
    canvas = Image.new("RGBA", (px, px), bg + (255,))
    if radius is not None:
        mask = rounded_mask(px, radius)
        canvas.putalpha(mask)

    # The leftover is forced even before it is halved. int(px * inset) leaves
    # an odd remainder at plenty of sizes - 32, 128 and 256 among them - and
    # the floor in `// 2` then puts the whole extra pixel on the right and
    # bottom, seating the mark one pixel left and high of centre. Measured on
    # the shipped icons: 32px had 9px of padding on the left and 10 on the
    # right, 256px had 73 and 74. One pixel is 3% of a 32px icon, which is why
    # it was reported as "not centred, too far to the left" in the Explorer
    # context menu and the tray.
    mark_px = max(1, int(px * inset))
    if (px - mark_px) % 2:
        mark_px = mark_px + 1 if mark_px < px else mark_px - 1
    offset = (px - mark_px) // 2
    canvas.alpha_composite(mark(mark_px, fg), (offset, offset))
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


def _bmp_frame(img: Image.Image) -> bytes:
    """One ICO frame in the BMP form Windows expects below 256px."""
    # tile() hands back RGB when it flattened for opacity, RGBA otherwise, and
    # the packing below reads four channels either way.
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()

    xor = bytearray()
    for y in range(h - 1, -1, -1):  # BMP rows run bottom-up
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))

    stride = ((w + 31) // 32) * 4
    mask = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray(stride)
        for x in range(w):
            if px[x, y][3] == 0:
                row[x // 8] |= 0x80 >> (x % 8)
        mask += row

    header = struct.pack(
        "<IiiHHIIiiII",
        40,        # biSize
        w,         # biWidth
        h * 2,     # biHeight: XOR bitmap plus AND mask
        1,         # biPlanes
        32,        # biBitCount
        0,         # biCompression = BI_RGB
        len(xor) + len(mask),
        0, 0, 0, 0,
    )
    return header + bytes(xor) + bytes(mask)


def _png_frame(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img = img.convert("RGBA")
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_ico(frames: list, *parts: str) -> None:
    """Write a multi-resolution .ico, each frame drawn at its own size.

    Not `Image.save(format="ICO", sizes=...)`. That takes ONE image and
    resamples it for every frame, so a 16px tray icon is a downsampled 256px
    render - mush, exactly where crispness matters most. Rendering each size
    from the vector and packing the frames by hand is the whole point.
    """
    frames = sorted(frames, key=lambda f: f.size[0])
    blobs = [_png_frame(f) if f.size[0] >= 256 else _bmp_frame(f)
             for f in frames]

    offset = 6 + 16 * len(frames)
    out = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    for frame, blob in zip(frames, blobs):
        w, h = frame.size
        out += struct.pack(
            "<BBBBHHII",
            0 if w >= 256 else w,
            0 if h >= 256 else h,
            0,   # palette entries: 0 for true colour
            0,
            1,   # colour planes
            32,  # bits per pixel
            len(blob),
            offset,
        )
        offset += len(blob)
    for blob in blobs:
        out += blob

    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(bytes(out))
    written.append(os.path.relpath(path, ROOT))


def on_transparent(px: int, master: str = "logo-white.svg") -> Image.Image:
    return render(master, px)


def bare_mark(px: int, *, color=PRIMARY, fill: float = 0.94) -> Image.Image:
    """The ghost alone on transparency, recoloured and scaled to fill the frame.

    For the Windows tray, where a tile is the wrong shape: at 16-24px the
    rounded square takes most of the canvas and leaves the ghost a few pixels
    tall inside it. Tray icons there are bare marks.

    The master pads the ghost inside a square viewBox, so it is rendered large,
    cropped to the ghost, and fitted by its longer side - rendering it at px
    directly would leave it as small as it is inside the tile. Recolouring
    keeps only the alpha, so the eyes stay knocked through: indigo with see-
    through eyes reads on both a dark and a light taskbar, which a white
    silhouette does not.
    """
    big = render("logo-white.svg", max(512, px * 16))
    ghost = big.crop(big.getbbox())
    scale = px * fill / max(ghost.size)
    size = (max(1, round(ghost.width * scale)), max(1, round(ghost.height * scale)))
    alpha = ghost.getchannel("A").resize(size, Image.LANCZOS)

    mark = Image.new("RGBA", size, color + (255,))
    mark.putalpha(alpha)
    canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    # Round rather than floor, for the same reason tile() evens its padding:
    # a floor puts every spare pixel on the left, and at 16px one is 6%.
    canvas.alpha_composite(
        mark, (round((px - size[0]) / 2), round((px - size[1]) / 2)))
    return canvas


IOS_ICONSET = ("ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")


def ios_app_icon() -> None:
    """iOS: one 1024px icon per appearance; Xcode derives every size.

    Light and dark are opaque and square - the OS masks the corners, and an
    app icon with any alpha is rejected at upload. Tinted (iOS 18+) is the
    mark alone in white on transparency: the system washes it in the user's
    tint over a dark backing of its own, so a tile of ours would come out as
    a solid block.
    """
    save(tile(1024), *IOS_ICONSET, "Icon-App-1024x1024@1x.png")
    save(tile(1024, bg=DARK_TILE), *IOS_ICONSET,
         "Icon-App-Dark-1024x1024@1x.png")
    tinted = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    mark_px = int(1024 * 0.92)
    off = (1024 - mark_px) // 2
    tinted.alpha_composite(mark(mark_px, WHITE), (off, off))
    save(tinted, *IOS_ICONSET, "Icon-App-Tinted-1024x1024@1x.png")

    def entry(filename, appearance=None):
        image = {"filename": filename, "idiom": "universal",
                 "platform": "ios", "size": "1024x1024"}
        if appearance:
            image["appearances"] = [{"appearance": "luminosity",
                                     "value": appearance}]
        return image

    contents = {
        "images": [
            entry("Icon-App-1024x1024@1x.png"),
            entry("Icon-App-Dark-1024x1024@1x.png", "dark"),
            entry("Icon-App-Tinted-1024x1024@1x.png", "tinted"),
        ],
        "info": {"author": "xcode", "version": 1},
    }
    import json
    path = os.path.join(ROOT, *IOS_ICONSET, "Contents.json")
    with open(path, "w") as fh:
        json.dump(contents, fh, indent=2)
        fh.write("\n")
    written.append(os.path.relpath(path, ROOT))


def ios_launch() -> None:
    """Launch screen: the indigo mark alone, over the dark storyboard - the
    dark icon without its tile, so its eyes show the storyboard's black."""
    for name, px in (("LaunchImage", 120), ("LaunchImage@2x", 240),
                     ("LaunchImage@3x", 360)):
        save(mark(px), "ios", "Runner", "Assets.xcassets",
             "LaunchImage.imageset", f"{name}.png")


def macos_app_icon() -> None:
    """macOS draws its own icons unmasked, so the rounded corner is ours."""
    for px in (16, 32, 64, 128, 256, 512, 1024):
        save(tile(px, radius=MASK_RADIUS, opaque=False),
             "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset",
             f"app_icon_{px}.png")


def android_icons() -> None:
    densities = (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3),
                 ("xxxhdpi", 4))
    for suffix, scale in densities:
        save(tile(int(48 * scale)), "android", "app", "src", "main", "res",
             f"mipmap-{suffix}", "ic_launcher.png")
        # The splash: the mark alone over the dark launch background.
        save(mark(int(120 * scale)), "android", "app", "src", "main",
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

    The foreground is the indigo ghost; the background is
    @color/ghost_icon_background, white in values/ and near-black in
    values-night/, which launchers that follow the system theme pick up.
    """
    for suffix, scale in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2),
                          ("xxhdpi", 3), ("xxxhdpi", 4)):
        px = int(108 * scale)
        # 0.50 of 108dp = 54dp, comfortably inside the 66dp safe zone.
        mark_px = max(1, int(px * 0.50))
        at = ((px - mark_px) // 2, (px - mark_px) // 2)
        for color, folder, name in (
                (PRIMARY, "mipmap", "ic_launcher_foreground.png"),
                (WHITE, "drawable", "ic_launcher_monochrome.png")):
            layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
            layer.alpha_composite(mark(mark_px, color), at)
            save(layer, "android", "app", "src", "main", "res",
                 f"{folder}-{suffix}", name)

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
    # Linux: a bare monochrome ghost, like Plasma's own tray icons. The panel
    # never recolours a file-path icon, so tray_service.dart picks between
    # these from the colour scheme: Breeze Dark's and Breeze's text colours.
    # 48px so it stays sharp on a 2x panel; Plasma scales it down to fit.
    save(bare_mark(48, color=(0xFC, 0xFC, 0xFC)), "assets", "icons",
         "tray_icon_linux.png")
    save(bare_mark(48, color=(0x23, 0x26, 0x29)), "assets", "icons",
         "tray_icon_linux_light_panel.png")
    # Windows loads this one, not the PNG - see tray_service.dart. It was left
    # out when this script took over from tool/generate_desktop_icons.py, so
    # the Windows tray kept showing the pre-rebrand mark while every other
    # surface changed. The bare ghost, not the tile - see bare_mark().
    write_ico([bare_mark(s) for s in (16, 20, 24, 32, 48)],
              "assets", "icons", "tray_icon.ico")


def flutter_assets() -> None:
    """The in-app header tints this white at runtime, so ship it white."""
    save(on_transparent(1024), "assets", "icons", "logo_white.png")
    # The app is dark, so in-app it shows the dark icon's mark: indigo, eyes
    # cut out to the dark behind it. The splash and the welcome screen.
    save(mark(1024), "assets", "icons", "logo_purple.png")
    save(on_transparent(1024, "logo-black.svg"), "assets", "icons",
         "logo_dark.png")
    # msix_config's logo_path: Windows derives every tile and taskbar
    # size from this one file, so the rounding has to be in it.
    save(tile(1024, radius=MASK_RADIUS, opaque=False),
         "assets", "icons", "app_icon.png")


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
        # An SVG favicon can follow the browser's theme, which no PNG can: the
        # light tile by default, the dark one under prefers-color-scheme.
        with open(os.path.join(BRAND, "logo-white.svg")) as fh:
            svg = fh.read()
        tinted = svg.replace(
            "<path",
            "<style>.tile{fill:" + _hex(LIGHT_TILE) + "}"
            "@media (prefers-color-scheme:dark){.tile{fill:"
            + _hex(DARK_TILE) + "}}</style>\n"
            '<rect class="tile" x="210.9" y="101.3" width="1655.9" '
            'height="1655.9" rx="240"/>\n<path',
            1,
        ).replace('fill="#FFFFFF"', f'fill="{_hex(PRIMARY)}"', 1)
        path = os.path.join(ROOT, base, "icons", "ghost.svg")
        with open(path, "w") as fh:
            fh.write(tinted)
        written.append(os.path.relpath(path, ROOT))


def _hex(rgb) -> str:
    return "#" + "".join(f"{c:02X}" for c in rgb)


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
    # The emails are dark, so the dark icon.
    card.alpha_composite(tile(128, radius=0.22, bg=DARK_TILE, opaque=False))
    for base in ("website", os.path.join("website", "dist")):
        save(card.convert("RGB"), base, "icons", "email-logo.png")


ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)


def favicon_ico() -> None:
    """Multi-resolution .ico for the website."""
    frames = [tile(s) for s in ICO_SIZES]
    for parts in (("website", "icons", "favicon.ico"),
                  ("website", "dist", "icons", "favicon.ico")):
        write_ico(frames, *parts)


def windows_app_icon() -> None:
    """Windows: the rounded corner is ours to draw, exactly as on macOS.

    Windows does not mask an app icon, so a square tile stays a hard square.
    Beside the rounded icons on a Windows 11 taskbar and in the Explorer
    context menu that reads as both oversized and off-centre - which is how it
    was reported, although the mark inside is centred to the pixel. The same
    inset looks right on macOS only because macos_app_icon rounds it.

    Same radius as macOS, so the one brand shows as one icon on both.
    """
    # One target. installer/ghostcopy.ico went with the Inno Setup script when
    # Windows became Store-only - the Store builds the package's icons from
    # msix_config's logo_path, so nothing else needs a .ico of its own.
    frames = [tile(s, radius=MASK_RADIUS, opaque=False) for s in ICO_SIZES]
    write_ico(frames, "windows", "runner", "resources", "app_icon.ico")


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
    windows_app_icon()
    print(f"wrote {len(written)} files")
    for w in sorted(written):
        print("   ", w)
