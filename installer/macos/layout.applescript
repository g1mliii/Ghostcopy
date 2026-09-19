on run argv
    set volumePath to item 1 of argv
    delay 2
    set volumeName to name of (info for (POSIX file volumePath as alias))
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 160, 860, 608}
            set theViewOptions to the icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 96
            set text size of theViewOptions to 14
            set background picture of theViewOptions to file ".background:background.png"
            set position of item "GhostCopy.app" of container window to {180, 210}
            set position of item "Applications" of container window to {480, 210}
            close
            open
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
