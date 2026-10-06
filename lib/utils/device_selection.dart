/// The stored auto-send target set after toggling one device.
///
/// One implementation, because this logic existed three times and the copies
/// drifted apart. Every rule below is a bug that reached a release in at least
/// one of them:
///
///   * An empty set is the all-devices sentinel, and the chips render every
///     destination as selected because of it. A toggle therefore has to start
///     from the full set, or the first tap ADDS the tapped device instead of
///     removing it - leaving only that device enabled and silently disabling
///     every other destination, the exact opposite of the tap.
///   * A toggle that would empty the set is refused, because empty means all:
///     turning the last destination off would have turned all of them back on.
///   * A full set folds back to the sentinel, so the stored value has one
///     representation and a device type added in a later release is still
///     covered by an existing all-devices preference.
///
/// [allDeviceTypes] should be the canonical list, so a platform added there is
/// handled here too. Returns null when the toggle is refused, which callers
/// treat as "leave everything as it was".
Set<String>? nextDeviceSelection({
  required Set<String> current,
  required List<String> allDeviceTypes,
  required String toggled,
}) {
  final updated = current.isEmpty
      ? Set<String>.from(allDeviceTypes)
      : Set<String>.from(current);

  if (!updated.remove(toggled)) updated.add(toggled);

  if (updated.isEmpty) return null;

  return updated.length == allDeviceTypes.length ? <String>{} : updated;
}

/// The destinations to offer as chips: the platforms the account has a device
/// on, in canonical order.
///
/// Listing every supported platform showed someone with a Mac and an iPhone
/// chips for Android and Linux, which they could toggle to no effect. Only
/// ownership decides, not the stored selection: turning one chip off expands
/// the all-devices sentinel into every type, so going by the selection would
/// bring the unowned chips straight back. A stored type with no device is
/// harmless - nothing is there to receive - and is offered again once a device
/// of that type is linked. With no devices known yet (still loading, or the
/// fetch failed) everything is offered, as before.
List<String> offeredDeviceTypes({
  required List<String> allDeviceTypes,
  required Iterable<String> ownedDeviceTypes,
}) {
  final owned = ownedDeviceTypes.toSet();
  if (owned.isEmpty) return allDeviceTypes;
  return [
    for (final type in allDeviceTypes)
      if (owned.contains(type)) type,
  ];
}
