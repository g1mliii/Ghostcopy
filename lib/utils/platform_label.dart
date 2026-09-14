/// Proper platform names for a `device_type_enum` value.
///
/// One mapping, shared by the models, the services and both UIs. It previously
/// existed as four private `_capitalizeFirst` helpers, which produced "Macos"
/// and "Ios" - those read as typos rather than as products.
///
/// Pairs with `iconForDeviceType`, which does the same job for the icon. That
/// one lives under `ui/` because it returns a Flutter type; this cannot follow
/// it there without dragging Flutter into the models and services.
String platformLabel(String deviceType) => switch (deviceType.toLowerCase()) {
  'windows' => 'Windows',
  'macos' => 'macOS',
  'linux' => 'Linux',
  'android' => 'Android',
  'ios' => 'iOS',
  _ =>
    deviceType.isEmpty
        ? deviceType
        : deviceType[0].toUpperCase() + deviceType.substring(1),
};
