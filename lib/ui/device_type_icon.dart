import 'package:flutter/material.dart';

/// The icon for a `device_type_enum` value.
///
/// One mapping, shared by everything that draws a platform: the target chips,
/// the history meta line, and the device list in Settings. It previously lived
/// as three identical switch statements in two files, which is the kind of
/// duplication that silently drifts - the same platform could end up with one
/// icon on a chip and a different one on the clip it produced.
///
/// Pairs with `platformLabel`, which does the same job for the text. That one
/// lives under `utils/` because it returns a String and the models and services
/// need it too; this cannot follow it there without dragging Flutter UI types
/// out of `ui/`.
IconData iconForDeviceType(String deviceType) =>
    switch (deviceType.toLowerCase()) {
      'windows' => Icons.laptop_windows,
      'macos' => Icons.laptop_mac,
      'linux' => Icons.laptop_chromebook,
      'android' => Icons.phone_android,
      'ios' => Icons.phone_iphone,
      // Also the deliberate answer for "everywhere" and for mixed targets: no
      // single platform icon would be honest about where the clip went.
      _ => Icons.devices,
    };
