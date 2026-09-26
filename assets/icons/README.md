# Icon Assets

Every file here is generated. Do not hand-edit them — edit the mark and re-run
the generator:

```bash
DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 tool/generate_brand_assets.py
```

The mark itself lives in `assets/brand/logo-white.svg` (with black and colour
variants beside it), and the generator rasterises it at each size rather than
restating its primitives in code.

This replaced `tool/generate_desktop_icons.py`, which is gone. That script drew
the pre-rebrand mark from Pillow primitives and claimed the same outputs, so
running it silently reverted the Windows and tray icons - one of
them, `tray_icon.ico`, was the live Windows tray asset and stayed reverted
because the new generator did not write it. One generator, one source of truth.

## What gets generated

| File | Used by |
|------|---------|
| `../../windows/runner/resources/app_icon.ico` | The Windows exe, title bar, taskbar and Alt-Tab, via `windows/runner/Runner.rc` |
| `tray_icon.ico` | Windows system tray (16/20/24/32/48 frames, picked per DPI) |
| `tray_icon_macos.png` | macOS menu bar |
| `tray_icon_linux.png` | Linux panels |
| `tray_icon.png` | Flutter-side previews that want a PNG |

`app_icon.png`, `logo_dark.png` and `logo_white.png` are the shared 1024px
brand art used by the Flutter UI and the mobile/msix packaging. They are not
produced by the generator.

## Why the tray icon is not the app icon

The app icon is the white ghost inside its indigo squircle. At the 16px the
tray actually renders, that container eats most of the canvas and the ghost
turns to mush, so the tray uses the bare ghost scaled to fill the frame.

It is drawn in brand indigo with the eyes knocked through to transparency,
which keeps it legible on both a dark and a light taskbar. A white silhouette —
what this used to ship — disappears entirely on a light taskbar.

## Why macOS is different

macOS menu bar icons are *template* images: black on transparent, with the
system tinting them to suit the menu bar's appearance. That is what makes the
icon invert in dark mode and when the bar is highlighted; a full-colour icon
cannot do it.

The tinting only happens if `isTemplate: true` is passed to
`trayManager.setIcon`, which `lib/services/impl/tray_service.dart` does on
macOS. The asset and that flag have to travel together — a black template image
without the flag is an invisible icon on a dark menu bar.
