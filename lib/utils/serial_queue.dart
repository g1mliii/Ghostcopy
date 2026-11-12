/// Runs async operations one at a time, in the order they were queued.
///
/// For the on-disk caches, whose writes and clears must not overtake each
/// other: a save that began just before a sign-out, landing after the clear
/// meant to follow it, would leave the previous account's data on disk.
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  /// Run [op] after everything queued before it.
  Future<void> run(Future<void> Function() op) {
    final next = _tail.then((_) => op());
    // A failed op must not wedge every one queued behind it.
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// Completes once everything queued so far has run.
  Future<void> get idle => _tail;
}
