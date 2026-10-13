#include "clipboard_change_channel.h"

#include <memory>

#include "clipboard_monitor.h"

namespace {
struct ClipboardChannel {
  FlMethodChannel* channel;
  std::unique_ptr<ClipboardMonitor> wayland;
  GtkClipboard* clipboard = nullptr;
  gulong signal = 0;
  int64_t count = 0;
  // Owner changes to anyone but this process, as Wayland's external count.
  int64_t external_count = 0;

  void Changed() {
    fl_method_channel_invoke_method(channel, "changed", nullptr, nullptr, nullptr, nullptr);
  }

  ~ClipboardChannel() {
    wayland.reset();
    if (signal) g_signal_handler_disconnect(clipboard, signal);
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    g_object_unref(channel);
  }
};

void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<ClipboardChannel*>(data);
  const char* method = fl_method_call_get_name(call);
  const bool external_only = g_strcmp0(method, "activityChangeCount") == 0;
  if (!external_only && g_strcmp0(method, "changeCount") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  int64_t count = external_only ? self->external_count : self->count;
  const bool available = self->wayland ? self->wayland->Read(&count, external_only) : true;
  g_autoptr(FlValue) value = available ? fl_value_new_int(count) : fl_value_new_null();
  fl_method_call_respond_success(call, value, nullptr);
}
}  // namespace

void register_clipboard_change_channel(FlView* view) {
  auto* self = new ClipboardChannel();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.ghostcopy.app/clipboard_change", FL_METHOD_CODEC(codec));
  const char* wayland = g_getenv("WAYLAND_DISPLAY");
  if (wayland && *wayland) {
    self->wayland = std::make_unique<ClipboardMonitor>([self]() { self->Changed(); });
  } else {
    self->clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    self->signal = g_signal_connect(self->clipboard, "owner-change",
        G_CALLBACK(+[](GtkClipboard*, GdkEventOwnerChange* event, gpointer data) {
          auto* state = static_cast<ClipboardChannel*>(data);
          ++state->count;
          // GDK resolves an owner window of this process to its own GdkWindow
          // and any other client's to a foreign one, so GhostCopy's writes are
          // told apart synchronously, with no race against the write landing.
          if (!event->owner ||
              gdk_window_get_window_type(event->owner) == GDK_WINDOW_FOREIGN) {
            ++state->external_count;
            // Dart only watches for other apps' copies; our own wake nothing.
            state->Changed();
          }
        }), self);
  }
  fl_method_channel_set_method_call_handler(self->channel, Handle, self, nullptr);
  g_object_set_data_full(G_OBJECT(view), "ghostcopy-clipboard-counter", self,
      +[](gpointer data) { delete static_cast<ClipboardChannel*>(data); });
}
