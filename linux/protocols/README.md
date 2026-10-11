# Wayland data-control protocol

`wlr-data-control-unstable-v1.xml` is vendored from
https://github.com/swaywm/wlr-protocols/blob/master/unstable/wlr-data-control-unstable-v1.xml.
Its copyright and permissive license are included in the XML and copied into
the release bundle by `tool/package_linux.py`.

The clipboard monitor only observes offers and selection events. It never
creates a data source, requests a payload, or sets either selection. Generated
C bindings are build outputs produced by `wayland-scanner`.
