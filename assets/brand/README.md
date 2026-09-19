# Brand masters

Every icon in the repo is generated from these three files. Do not hand-edit
the generated PNGs - change a master and run:

```bash
DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 tool/generate_brand_assets.py
```

| File | Use |
|------|-----|
| `logo-white.svg` | The mark, flat white, eyes knocked out with `fill-rule="evenodd"`. Source for almost everything: app icons on the purple tile, launch screens, notification icon, in-app header. |
| `logo-black.svg` | Same geometry in black. macOS menu bar only - a template image there must be black, or it disappears in a light menu bar. |
| `logo-colour.svg` | The original three-colour artwork (outline, body, tail shading). Kept for print and marketing at large sizes. Deliberately not used for app icons: at 40pt, where iOS draws the icon in Settings and Spotlight, the outline and the grey shading turn to mush. |

The masters carry no text. The source artwork had "GHOSTCOPY / MINIMAL &
FLUID" baked in as 23 paths; a wordmark inside an app icon is unreadable at
small sizes and both Apple and Google advise against it.
