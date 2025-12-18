# Tray Icon Assets

## Required Files

For the system tray to display properly, you need to add the following icon files to this directory:

### Windows
- **tray_icon.ico** - Windows tray icon (16x16, 32x32, 48x48 multi-resolution ICO file)

### macOS
- **tray_icon.png** - macOS menu bar icon (22x22 PNG, monochrome recommended for native look)

### Linux
- **tray_icon.png** - Linux tray icon (22x22 or 24x24 PNG)

## Icon Design Guidelines

- **Style**: Simple, monochrome ghost icon to match "GhostCopy" branding
- **Colors**:
  - Windows: Full color or white on transparent
  - macOS: Black on transparent (system will invert for dark mode)
  - Linux: Full color or white on transparent
- **Padding**: Leave 2-3px padding around the icon for visual breathing room

## Creating Icons

You can use tools like:
- **Figma/Sketch** - Design the icon
- **ImageMagick** - Convert PNG to ICO: `convert icon.png -define icon:auto-resize=48,32,16 tray_icon.ico`
- **Online converters** - [icoconvert.com](https://icoconvert.com), [cloudconvert.com](https://cloudconvert.com)

## Temporary Solution

Until you add custom icons, the app will attempt to use these paths but may show a default system icon or no icon.
