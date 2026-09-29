"""Generate website/icons/og-card.png, the 1200x630 link-preview card.

Shared in Messages, Slack or X, a link shows its og:image. The square app
icon rendered as a small thumbnail; this is the wide card those previews are
sized for. Colours match lib/ui/theme/colors.dart and the site.

    python3 tool/generate_og_card.py

Uses Helvetica Neue from macOS (the site's Inter is not installed locally).
"""

import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "website", "icons", "icon-512.png")
OUT = os.path.join(ROOT, "website", "icons", "og-card.png")
FONT = "/System/Library/Fonts/HelveticaNeue.ttc"

W, H = 1200, 630
BG = (15, 15, 19)  # #0F0F13
INK_4 = (245, 246, 250)
INK_2 = (150, 152, 163)
ACCENT = (102, 112, 255)  # #6670FF


def font(size, index):
    return ImageFont.truetype(FONT, size, index=index)


def main():
    card = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(card)

    icon = Image.open(ICON).convert("RGBA").resize((168, 168), Image.LANCZOS)
    # Rounded like the app icon and the site's own logo tile.
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 167, 167), radius=38, fill=255)
    card.paste(icon, (96, 96), mask)

    bold, regular = font(96, 1), font(52, 0)
    draw.text((96, 286), "GhostCopy", font=bold, fill=INK_4)
    draw.text((96, 400), "Copy on your Mac.", font=regular, fill=INK_2)
    draw.text((96, 462), "Paste on your iPhone.", font=regular, fill=INK_4)

    small = font(30, 0)
    label = "ghostcopy.app  ·  Mac  ·  iPhone  ·  Windows"
    # Its own line under the tagline, left-aligned with everything else.
    draw.text((96, 550), label, font=small, fill=ACCENT)

    card.save(OUT, optimize=True)
    print(f"wrote {OUT} ({os.path.getsize(OUT) // 1024} KB)")


if __name__ == "__main__":
    main()
