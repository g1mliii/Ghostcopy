#ifndef GHOSTCOPY_CLIPBOARD_MONITOR_H_
#define GHOSTCOPY_CLIPBOARD_MONITOR_H_

#include <glib.h>
#include <wayland-client.h>

#include <cstdint>
#include <functional>
#include <set>

#include "wlr-data-control-client.h"

// Observes selection metadata only. Never requests data or takes ownership.
// This connection is independent of GTK's XWayland connection, so native
// Wayland copies are visible even while the Flutter window is unfocused.
class ClipboardMonitor {
 public:
  explicit ClipboardMonitor(std::function<void()> changed);
  ~ClipboardMonitor();
  ClipboardMonitor(const ClipboardMonitor&) = delete;
  ClipboardMonitor& operator=(const ClipboardMonitor&) = delete;

  // Returns false while connecting or if data-control is unavailable. Callers
  // must fall back to reading, never treat an unavailable counter as unchanged.
  bool Read(int64_t* count);

 private:
  void Connect();
  void Disconnect();
  void Flush();
  bool Drain();
  void BindDevice();
  static gboolean Dispatch(gint fd, GIOCondition condition, gpointer data);
  static void Global(void*, wl_registry*, uint32_t, const char*, uint32_t);
  static void GlobalRemoved(void*, wl_registry*, uint32_t);
  static void Offer(void*, zwlr_data_control_device_v1*, zwlr_data_control_offer_v1*);
  static void Selection(void*, zwlr_data_control_device_v1*, zwlr_data_control_offer_v1*);
  static void Primary(void*, zwlr_data_control_device_v1*, zwlr_data_control_offer_v1*);
  static void Finished(void*, zwlr_data_control_device_v1*);
  static void Mime(void*, zwlr_data_control_offer_v1*, const char*);
  void ReplaceOffer(zwlr_data_control_offer_v1** current, zwlr_data_control_offer_v1* next);

  std::function<void()> changed_;
  wl_display* display_ = nullptr;
  wl_registry* registry_ = nullptr;
  wl_seat* seat_ = nullptr;
  zwlr_data_control_manager_v1* manager_ = nullptr;
  zwlr_data_control_device_v1* device_ = nullptr;
  zwlr_data_control_offer_v1* selection_ = nullptr;
  zwlr_data_control_offer_v1* primary_ = nullptr;
  std::set<zwlr_data_control_offer_v1*> offers_;
  uint32_t seat_name_ = 0;
  uint32_t manager_name_ = 0;
  guint source_ = 0;
  int64_t count_ = 0;
  gint64 retry_at_ = 0;
  bool ready_ = false;
  bool failed_ = false;
};

#endif
