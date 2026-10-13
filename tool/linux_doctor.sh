#!/usr/bin/env bash
# Read-only session diagnostics; never reads or prints clipboard contents.
set -u
printf 'Desktop: %s\nSession: %s\nWayland socket: %s\nXWayland display: %s\n' \
  "${XDG_CURRENT_DESKTOP:-unset}" "${XDG_SESSION_TYPE:-unset}" \
  "${WAYLAND_DISPLAY:-unset}" "${DISPLAY:-unset}"
failed=0
for command in wl-paste python3 gdbus; do
  if command -v "$command" >/dev/null 2>&1; then
    printf 'OK: %s\n' "$command"
  else
    printf 'MISSING: %s\n' "$command"
    failed=1
  fi
done
if command -v gdbus >/dev/null 2>&1; then
  for item in \
    'org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop' \
    'org.freedesktop.Notifications /org/freedesktop/Notifications' \
    'org.kde.StatusNotifierWatcher /StatusNotifierWatcher' \
    'org.freedesktop.secrets /org/freedesktop/secrets'; do
    read -r service object <<< "$item"
    if gdbus introspect --session --dest "$service" --object-path "$object" >/dev/null 2>&1; then
      printf 'OK: %s\n' "$service"
    else
      printf 'UNAVAILABLE: %s\n' "$service"
      failed=1
    fi
  done
fi
exit "$failed"
