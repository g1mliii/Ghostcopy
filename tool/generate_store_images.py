#!/usr/bin/env python3
"""Microsoft Store listing images, composed from the app icon.

    python3 tool/generate_store_images.py

Writes to docs/microsoft-store-images/, which is NOT shipped - these are
upload artefacts for Partner Center, not app assets.

Separate from generate_brand_assets.py on purpose. That one owns everything
the app itself contains and rasterises the master SVGs to do it, which needs
Cairo. These are compositions of an icon that generator already produced, so
they need only Pillow - and Cairo does not load on Windows, which is where
the Store submission is made.

Store logos are optional: without them Partner Center falls back to the tile
images inside the package. The 9:16 poster is worth providing anyway, since
it is the main logo customers see on Windows 10/11 and the package has
nothing that shape.
"""

import os

from PIL import Image

# Pillow-only at import time: generate_brand_assets loads Cairo inside
# render(), so taking its constants from there does not need Cairo here.
from generate_brand_assets import BACKGROUND, ROOT

ICON = os.path.join(ROOT, "assets", "icons", "app_icon.png")
OUT = os.path.join(ROOT, "docs", "microsoft-store-images")

# Share of the shorter edge the icon occupies. Comfortably inside Partner
# Center's safe areas, and leaves the mark room to read at tile size.
ICON_SHARE = 0.62


def canvas(width: int, height: int) -> Image.Image:
    """The icon centred on the brand background.

    The icon is a purple tile, so it needs a surround that is not also purple.
    """
    base = Image.new("RGBA", (width, height), BACKGROUND + (255,))
    edge = int(min(width, height) * ICON_SHARE)
    base.alpha_composite(plain(edge), ((width - edge) // 2, (height - edge) // 2))
    return base


def plain(size: int) -> Image.Image:
    """Just the icon, transparency intact - what a tile slot expects."""
    return Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)


def save(img: Image.Image, name: str) -> None:
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    img.save(path)
    print(f"  {name:34s} {img.width}x{img.height}")


def main() -> None:
    print("9:16 poster art (main logo on Windows 10/11):")
    save(canvas(720, 1080), "poster-720x1080.png")
    save(canvas(1440, 2160), "poster-1440x2160.png")

    print("1:1 box art:")
    save(canvas(1080, 1080), "boxart-1080x1080.png")
    save(canvas(2160, 2160), "boxart-2160x2160.png")

    # These mirror what the package already carries, so uploading them is
    # optional - useful only to keep every surface identical to the icon
    # rather than to msix's own scaling.
    print("store display tiles:")
    for size in (300, 150, 71):
        save(plain(size), f"tile-{size}x{size}.png")

    print(f"\nwritten to {os.path.relpath(OUT, ROOT)}")
    print("Not app assets - upload artefacts. Screenshots still have to be")
    print("taken by hand from the running app.")


if __name__ == "__main__":
    main()
