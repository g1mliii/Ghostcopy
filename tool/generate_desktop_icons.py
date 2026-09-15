"""Regenerate the desktop icon set from the GhostCopy mark.

The mark's source of truth is website/icons/ghost.svg. Rather than depend on an
SVG rasteriser, the handful of primitives that make up that file are restated
here and drawn with Pillow. Keep the two in step: if the .svg changes, change
the constants below to match.

Every size is drawn at its own dimensions from the vector and supersampled
down, instead of resizing one big PNG. That matters at 16px, where a downscaled
256px render turns the eyes into grey smudges.

Usage:  python tool/generate_desktop_icons.py
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

# --- the mark, in the 32-unit viewBox of website/icons/ghost.svg ---------------

INDIGO = (0x66, 0x70, 0xFF, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF, 0xFF)
BLACK = (0x00, 0x00, 0x00, 0xFF)
CLEAR = (0, 0, 0, 0)

VIEWBOX = 32.0
SQUIRCLE_RADIUS = 9.0

# path: M6 15 a10 10 0 0 1 20 0 v8 a5 5 0 0 1 -10 0 a5 5 0 0 1 -10 0 z
HEAD = (16.0, 15.0, 10.0)          # centre x, centre y, radius of the domed top
TORSO = (6.0, 15.0, 26.0, 23.0)    # the straight-sided middle
FEET = ((11.0, 23.0, 5.0), (21.0, 23.0, 5.0))  # the two rounded lobes
EYES = ((12.4, 15.6, 2.1, 2.7), (19.6, 15.6, 2.1, 2.7))  # cx, cy, rx, ry

# The ghost alone, without the squircle around it.
GLYPH_BOX = (6.0, 5.0, 26.0, 28.0)

SUPERSAMPLE = 16


def _draw_ghost(draw: ImageDraw.ImageDraw, unit, fill) -> None:
    """Paint the ghost body. `unit` maps viewBox coordinates onto the canvas."""
    cx, cy, r = HEAD
    draw.pieslice(unit(cx - r, cy - r, cx + r, cy + r), 180, 360, fill=fill)
    draw.rectangle(unit(*TORSO), fill=fill)
    for fx, fy, fr in FEET:
        draw.pieslice(unit(fx - fr, fy - fr, fx + fr, fy + fr), 0, 180, fill=fill)


def _draw_eyes(draw: ImageDraw.ImageDraw, unit, fill) -> None:
    for ex, ey, erx, ery in EYES:
        draw.ellipse(unit(ex - erx, ey - ery, ex + erx, ey + ery), fill=fill)


def render_app_icon(size: int) -> Image.Image:
    """The full mark: white ghost on the indigo squircle. For app/exe/installer."""
    s = size * SUPERSAMPLE
    scale = s / VIEWBOX

    def unit(*coords):
        return tuple(c * scale for c in coords)

    img = Image.new("RGBA", (s, s), CLEAR)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle((0, 0, s - 1, s - 1), radius=SQUIRCLE_RADIUS * scale, fill=INDIGO)
    _draw_ghost(draw, unit, WHITE)
    _draw_eyes(draw, unit, INDIGO)
    return img.resize((size, size), Image.LANCZOS)


def render_glyph(size: int, fill, padding: float = 0.06) -> Image.Image:
    """The bare ghost, eyes knocked out to transparent, sized to fill the canvas.

    Used for the tray, where the icon is 16-24px and the squircle would shrink
    the ghost to an unreadable smudge. The knocked-out eyes let the taskbar
    colour show through, so the glyph reads on light and dark panels alike.
    """
    s = size * SUPERSAMPLE
    gx0, gy0, gx1, gy1 = GLYPH_BOX
    pad = s * padding
    scale = min((s - 2 * pad) / (gx1 - gx0), (s - 2 * pad) / (gy1 - gy0))
    off_x = (s - (gx1 - gx0) * scale) / 2 - gx0 * scale
    off_y = (s - (gy1 - gy0) * scale) / 2 - gy0 * scale

    def unit(*coords):
        out = []
        for i, c in enumerate(coords):
            out.append(c * scale + (off_x if i % 2 == 0 else off_y))
        return tuple(out)

    img = Image.new("RGBA", (s, s), CLEAR)
    draw = ImageDraw.Draw(img)
    _draw_ghost(draw, unit, fill)

    # Punch the eyes through to transparency rather than painting them a colour,
    # so the icon sits on any panel background.
    holes = Image.new("L", (s, s), 255)
    _draw_eyes(ImageDraw.Draw(holes), unit, 0)
    img.putalpha(ImageChops.darker(img.getchannel("A"), holes))
    return img.resize((size, size), Image.LANCZOS)


# --- ICO writing --------------------------------------------------------------
#
# Pillow's ICO writer resamples a single source image for every frame. We want
# each frame drawn at its own size, so the container is assembled by hand.
# Frames below 256px are stored as BMP because a few older Windows surfaces
# (some shell dialogs, the Alt-Tab fallback) still mishandle PNG-in-ICO;
# 256px is stored as PNG, which is what Windows expects there.


def _bmp_frame(img: Image.Image) -> bytes:
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
    import io

    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_ico(path: Path, frames: list[Image.Image]) -> None:
    frames = sorted(frames, key=lambda f: f.size[0])
    blobs = [_png_frame(f) if f.size[0] >= 256 else _bmp_frame(f) for f in frames]

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

    path.write_bytes(bytes(out))
    print(f"  {path.relative_to(ROOT)}  ({len(frames)} frames, {len(out):,} bytes)")


def write_png(path: Path, img: Image.Image) -> None:
    img.save(path, format="PNG", optimize=True)
    print(f"  {path.relative_to(ROOT)}  ({img.size[0]}px, {path.stat().st_size:,} bytes)")


def main() -> None:
    # Windows wants every size the shell asks for: tray and titlebar at 16,
    # Explorer's list views through 48, and the large tiles at 128/256.
    app_sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    app_frames = [render_app_icon(s) for s in app_sizes]

    print("app icon (white ghost on the indigo squircle):")
    write_ico(ROOT / "windows" / "runner" / "resources" / "app_icon.ico", app_frames)
    # The Inno Setup script's SetupIconFile points here. It lives beside the
    # .iss rather than in assets/, because pubspec.yaml ships all of
    # assets/icons/ and the installer's icon has no business inside the app.
    write_ico(ROOT / "installer" / "ghostcopy.ico", app_frames)

    print("tray icon (bare indigo glyph, eyes knocked through):")
    tray_sizes = [16, 20, 24, 32, 48]
    write_ico(
        ROOT / "assets" / "icons" / "tray_icon.ico",
        [render_glyph(s, INDIGO) for s in tray_sizes],
    )
    # Kept for the Flutter-side previews that still reference a PNG tray asset.
    write_png(ROOT / "assets" / "icons" / "tray_icon.png", render_glyph(64, INDIGO))
    # Linux panels ask for 24px and draw it as-is.
    write_png(ROOT / "assets" / "icons" / "tray_icon_linux.png", render_glyph(24, INDIGO))

    print("macOS menu bar (black template, tinted by the system):")
    # 44px is the @2x of the 22pt menu bar slot. Black on transparent is a
    # requirement of template images, not a style choice: AppKit reads the
    # alpha and repaints it, which is what makes it invert in dark mode.
    write_png(ROOT / "assets" / "icons" / "tray_icon_macos.png", render_glyph(44, BLACK))


if __name__ == "__main__":
    main()
