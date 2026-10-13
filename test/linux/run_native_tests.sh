#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=build/linux-native-tests
mkdir -p "$out"
protocol=linux/protocols/wlr-data-control-unstable-v1.xml
wayland-scanner client-header "$protocol" "$out/wlr-data-control-client.h"
wayland-scanner server-header "$protocol" "$out/wlr-data-control-server.h"
wayland-scanner private-code "$protocol" "$out/wlr-data-control-protocol.c"
cc -c "$out/wlr-data-control-protocol.c" -o "$out/protocol.o" $(pkg-config --cflags wayland-client)
c++ -std=c++14 -Wall -Wextra -Werror -g \
  -I"$out" -Ilinux/runner linux/runner/clipboard_monitor.cc \
  test/linux/clipboard_monitor_test.cc "$out/protocol.o" \
  $(pkg-config --cflags --libs glib-2.0 wayland-client wayland-server) \
  -o "$out/clipboard_monitor_test"
"$out/clipboard_monitor_test"
