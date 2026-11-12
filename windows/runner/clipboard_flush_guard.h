#ifndef RUNNER_CLIPBOARD_FLUSH_GUARD_H_
#define RUNNER_CLIPBOARD_FLUSH_GUARD_H_

#include <cstdint>
#include <optional>

// A successful OLE flush may retain our owner window and emit another change
// notification. Only a new clipboard sequence can require another flush.
class ClipboardFlushGuard {
 public:
  bool NeedsFlush(uint32_t sequence) const {
    return sequence == 0 || !completed_sequence_ ||
           sequence != *completed_sequence_;
  }

  void DidFlush(uint32_t sequence) { completed_sequence_ = sequence; }

 private:
  std::optional<uint32_t> completed_sequence_;
};

#endif  // RUNNER_CLIPBOARD_FLUSH_GUARD_H_
