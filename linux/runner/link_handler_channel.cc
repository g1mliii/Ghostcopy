#include "link_handler_channel.h"

#include "link_handler_icon.h"

namespace {
struct PendingHandler {
  FlMethodCall* call;
  gchar* name;
};

void RespondWithIcon(GBytes* png, gpointer data) {
  auto* pending = static_cast<PendingHandler*>(data);
  g_autoptr(FlValue) value = fl_value_new_map();
  fl_value_set_string_take(value, "name", fl_value_new_string(pending->name));
  if (png) {
    gsize length = 0;
    const auto* bytes = static_cast<const uint8_t*>(g_bytes_get_data(png, &length));
    fl_value_set_string_take(value, "icon", fl_value_new_uint8_list(bytes, length));
  }
  fl_method_call_respond_success(pending->call, value, nullptr);
  g_object_unref(pending->call);
  g_free(pending->name);
  delete pending;
}

void Handle(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (g_strcmp0(fl_method_call_get_name(call), "handlerFor") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  FlValue* url = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
      ? fl_value_lookup_string(args, "url") : nullptr;
  g_autofree gchar* scheme = url && fl_value_get_type(url) == FL_VALUE_TYPE_STRING
      ? g_uri_parse_scheme(fl_value_get_string(url)) : nullptr;
  g_autoptr(GAppInfo) app = scheme
      ? g_app_info_get_default_for_uri_scheme(scheme) : nullptr;
  if (!app) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  const gchar* name = g_app_info_get_display_name(app);
  if (!name || !*name) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  auto* pending = new PendingHandler{
      FL_METHOD_CALL(g_object_ref(call)), g_strdup(name)};
  // GTK resolves the desktop's selected theme, inheritance, SVGs, and file
  // icons. Do not substitute a hard-coded hicolor path for the user's theme.
  load_link_handler_icon(gtk_icon_theme_get_default(), g_app_info_get_icon(app),
                          RespondWithIcon, pending);
}
}  // namespace

void register_link_handler_channel(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.ghostcopy/link_handler", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, Handle, nullptr, nullptr);
  g_object_set_data_full(G_OBJECT(view), "ghostcopy-link-handler", channel,
                         g_object_unref);
}
