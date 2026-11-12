#include "link_handler_icon.h"

namespace {
struct PendingIcon {
  GtkIconInfo* info;
  LinkIconCallback callback;
  gpointer data;
};

void IconLoaded(GObject* source, GAsyncResult* result, gpointer data) {
  auto* pending = static_cast<PendingIcon*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkPixbuf) pixels = gtk_icon_info_load_icon_finish(
      GTK_ICON_INFO(source), result, &error);
  g_autoptr(GBytes) png = nullptr;
  if (pixels && gdk_pixbuf_get_width(pixels) <= 128 &&
      gdk_pixbuf_get_height(pixels) <= 128) {
    gchar* buffer = nullptr;
    gsize length = 0;
    if (gdk_pixbuf_save_to_buffer(pixels, &buffer, &length, "png", nullptr,
                                 nullptr)) {
      png = g_bytes_new_take(buffer, length);
    }
  }
  pending->callback(png, pending->data);
  g_object_unref(pending->info);
  delete pending;
}
}  // namespace

void load_link_handler_icon(GtkIconTheme* theme, GIcon* icon,
                            LinkIconCallback callback, gpointer data) {
  GtkIconInfo* info = theme && icon ? gtk_icon_theme_lookup_by_gicon(
      theme, icon, 64, GTK_ICON_LOOKUP_FORCE_SIZE) : nullptr;
  if (!info) {
    callback(nullptr, data);
    return;
  }
  auto* pending = new PendingIcon{info, callback, data};
  gtk_icon_info_load_icon_async(info, nullptr, IconLoaded, pending);
}
