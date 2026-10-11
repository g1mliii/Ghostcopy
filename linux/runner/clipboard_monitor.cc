#include "clipboard_monitor.h"

#include <glib-unix.h>
#include <poll.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <utility>

ClipboardMonitor::ClipboardMonitor(std::function<void()> changed)
    : changed_(std::move(changed)) {}

ClipboardMonitor::~ClipboardMonitor() { Disconnect(); }

bool ClipboardMonitor::Read(int64_t* count) {
  if (!display_ && g_get_monotonic_time() >= retry_at_) Connect();
  if (display_ && !Drain()) Disconnect();
  if (display_) Flush();
  if (!ready_ || failed_) return false;
  *count = count_;
  return true;
}

bool ClipboardMonitor::Drain() {
  // A counter query can beat the GLib fd callback. Consume already-arrived
  // events before answering Smart Receive, without blocking the UI thread.
  while (wl_display_prepare_read(display_) != 0) {
    if (wl_display_dispatch_pending(display_) < 0 || failed_) return false;
  }
  pollfd fd = {wl_display_get_fd(display_), POLLIN, 0};
  const int result = poll(&fd, 1, 0);
  if (result > 0 && (fd.revents & POLLIN)) {
    if (wl_display_read_events(display_) < 0) return false;
  } else {
    wl_display_cancel_read(display_);
    if ((result < 0 && errno != EINTR) || (fd.revents & (POLLERR | POLLHUP | POLLNVAL))) return false;
  }
  return wl_display_dispatch_pending(display_) >= 0 && !failed_;
}

void ClipboardMonitor::Connect() {
  retry_at_ = g_get_monotonic_time() + 30 * G_TIME_SPAN_SECOND;
  display_ = wl_display_connect(nullptr);
  if (!display_) return;
  failed_ = false;
  registry_ = wl_display_get_registry(display_);
  static const wl_registry_listener listener = {Global, GlobalRemoved};
  wl_registry_add_listener(registry_, &listener, this);
  // No blocking roundtrips on the GTK thread. The counter stays unavailable
  // until the compositor delivers its initial selection.
  source_ = g_unix_fd_add(wl_display_get_fd(display_),
                         static_cast<GIOCondition>(G_IO_IN | G_IO_ERR | G_IO_HUP),
                         Dispatch, this);
  Flush();
}

void ClipboardMonitor::Disconnect() {
  ready_ = false;
  if (source_) g_source_remove(source_);
  source_ = 0;
  for (auto* offer : offers_) zwlr_data_control_offer_v1_destroy(offer);
  offers_.clear();
  selection_ = primary_ = nullptr;
  if (device_) zwlr_data_control_device_v1_destroy(device_);
  if (manager_) zwlr_data_control_manager_v1_destroy(manager_);
  if (seat_) wl_seat_destroy(seat_);
  if (registry_) wl_registry_destroy(registry_);
  if (display_) wl_display_disconnect(display_);
  device_ = nullptr;
  manager_ = nullptr;
  seat_ = nullptr;
  registry_ = nullptr;
  display_ = nullptr;
  seat_name_ = manager_name_ = 0;
  retry_at_ = g_get_monotonic_time() + 30 * G_TIME_SPAN_SECOND;
}

void ClipboardMonitor::Flush() {
  if (!display_) return;
  const int result = wl_display_flush(display_);
  if (result < 0 && errno != EAGAIN) {
    Disconnect();
    return;
  }
  // Watch writability only under backpressure; otherwise it would spin while
  // idle. All use of this private connection stays on the GTK thread.
  if (result < 0) {
    if (source_) g_source_remove(source_);
    source_ = g_unix_fd_add(wl_display_get_fd(display_),
                           static_cast<GIOCondition>(G_IO_IN | G_IO_OUT | G_IO_ERR | G_IO_HUP),
                           Dispatch, this);
  }
}

gboolean ClipboardMonitor::Dispatch(gint, GIOCondition condition, gpointer data) {
  auto* self = static_cast<ClipboardMonitor*>(data);
  if ((condition & (G_IO_ERR | G_IO_HUP)) ||
      ((condition & G_IO_IN) && !self->Drain()) ||
      self->failed_) {
    self->source_ = 0;  // The main loop removes this source on return.
    self->Disconnect();
    return G_SOURCE_REMOVE;
  }
  if (condition & G_IO_OUT) {
    g_source_remove(self->source_);
    self->source_ = g_unix_fd_add(wl_display_get_fd(self->display_),
        static_cast<GIOCondition>(G_IO_IN | G_IO_ERR | G_IO_HUP), Dispatch, self);
    self->Flush();
    return G_SOURCE_REMOVE;
  }
  self->Flush();
  return G_SOURCE_CONTINUE;
}

void ClipboardMonitor::Global(void* data, wl_registry* registry, uint32_t name,
                              const char* interface, uint32_t version) {
  auto* self = static_cast<ClipboardMonitor*>(data);
  if (strcmp(interface, wl_seat_interface.name) == 0 && !self->seat_) {
    self->seat_ = static_cast<wl_seat*>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
    static const wl_seat_listener seat_listener = {
        +[](void*, wl_seat*, uint32_t) {}, +[](void*, wl_seat*, const char*) {}};
    wl_seat_add_listener(self->seat_, &seat_listener, self);
    self->seat_name_ = name;
  } else if (strcmp(interface, zwlr_data_control_manager_v1_interface.name) == 0 && !self->manager_) {
    self->manager_ = static_cast<zwlr_data_control_manager_v1*>(wl_registry_bind(
        registry, name, &zwlr_data_control_manager_v1_interface, std::min(version, 2u)));
    self->manager_name_ = name;
  }
  self->BindDevice();
}

void ClipboardMonitor::GlobalRemoved(void* data, wl_registry*, uint32_t name) {
  auto* self = static_cast<ClipboardMonitor*>(data);
  if (name == self->seat_name_ || name == self->manager_name_) {
    self->ready_ = false;
    self->failed_ = true;
  }
}

void ClipboardMonitor::BindDevice() {
  if (!manager_ || !seat_ || device_) return;
  device_ = zwlr_data_control_manager_v1_get_data_device(manager_, seat_);
  static const zwlr_data_control_device_v1_listener listener = {
      Offer, Selection, Finished, Primary};
  zwlr_data_control_device_v1_add_listener(device_, &listener, this);
}

void ClipboardMonitor::Mime(void*, zwlr_data_control_offer_v1*, const char*) {}

void ClipboardMonitor::Offer(void* data, zwlr_data_control_device_v1*,
                             zwlr_data_control_offer_v1* offer) {
  auto* self = static_cast<ClipboardMonitor*>(data);
  self->offers_.insert(offer);
  static const zwlr_data_control_offer_v1_listener listener = {Mime};
  zwlr_data_control_offer_v1_add_listener(offer, &listener, self);
}

void ClipboardMonitor::ReplaceOffer(zwlr_data_control_offer_v1** current,
                                    zwlr_data_control_offer_v1* next) {
  if (*current) {
    offers_.erase(*current);
    zwlr_data_control_offer_v1_destroy(*current);
  }
  *current = next;
}

void ClipboardMonitor::Selection(void* data, zwlr_data_control_device_v1*,
                                 zwlr_data_control_offer_v1* offer) {
  auto* self = static_cast<ClipboardMonitor*>(data);
  self->ReplaceOffer(&self->selection_, offer);
  self->ready_ = true;
  // Never reset on reconnect: the old counter must not suppress a new copy.
  ++self->count_;
  self->changed_();
}

void ClipboardMonitor::Primary(void* data, zwlr_data_control_device_v1*,
                               zwlr_data_control_offer_v1* offer) {
  static_cast<ClipboardMonitor*>(data)->ReplaceOffer(
      &static_cast<ClipboardMonitor*>(data)->primary_, offer);
}

void ClipboardMonitor::Finished(void* data, zwlr_data_control_device_v1*) {
  auto* self = static_cast<ClipboardMonitor*>(data);
  self->ready_ = false;
  self->failed_ = true;
}
