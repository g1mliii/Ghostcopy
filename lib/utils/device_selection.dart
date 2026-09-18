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
