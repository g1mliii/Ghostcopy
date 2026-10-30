import 'package:flutter/foundation.dart';

/// [platform] as a `device_type_enum` value.
///
/// For code that should follow `defaultTargetPlatform` - which a widget test
/// can override - rather than dart:io's Platform, as
/// `ClipboardRepository.getCurrentDeviceType` does for what a clip is tagged
/// with. Lives apart from `platformLabel` so that file stays free of Flutter.
String deviceTypeFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.macOS => 'macos',
  TargetPlatform.windows => 'windows',
  TargetPlatform.linux || TargetPlatform.fuchsia => 'linux',
};
