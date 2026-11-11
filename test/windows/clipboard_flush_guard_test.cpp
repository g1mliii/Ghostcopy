#include "clipboard_flush_guard.h"

#include <iostream>

int main() {
  ClipboardFlushGuard guard;
  if (!guard.NeedsFlush(100)) return 1;

  // Flushing advances the sequence but leaves the same owner. Its own queued
  // notifications must not request more flushes and starve mouse input.
  guard.DidFlush(102);
  for (int event = 0; event < 10000; ++event) {
    if (guard.NeedsFlush(102)) return 2;
  }

  // The next write from the same owner is still new and must be rendered.
  if (!guard.NeedsFlush(103)) return 3;

  // A failed flush is not committed: the same clipboard state stays retryable.
  if (!guard.NeedsFlush(103)) return 4;
  guard.DidFlush(105);
  if (guard.NeedsFlush(105)) return 5;
  if (!guard.NeedsFlush(106)) return 6;

  // An unavailable sequence must not permanently suppress future work.
  guard.DidFlush(0);
  if (!guard.NeedsFlush(0) || !guard.NeedsFlush(107)) return 7;
  std::cout << "Clipboard flush feedback, new writes, and retries passed.\n";
  return 0;
}
