#include "include/hotkey_manager_linux/hotkey_manager_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk/gdkkeysyms.h>
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <sys/utsname.h>

#include <cstring>

#include <keybinder.h>

#include <algorithm>
#include <map>
#include <string>
#include <vector>

#include "hotkey_manager_linux_plugin_private.h"

#define HOTKEY_MANAGER_LINUX_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), hotkey_manager_linux_plugin_get_type(), \
                              HotkeyManagerLinuxPlugin))

std::map<std::string, std::string> hotkey_id_map;
FlEventChannel* event_channel;

struct _HotkeyManagerLinuxPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(HotkeyManagerLinuxPlugin,
              hotkey_manager_linux_plugin,
              g_object_get_type())

// keybinder only reports presses. Observe the raw event before its root
// filter so a physical release rearms the shortcut. Classic X11 autorepeat
// sends a synthetic release/press pair with the same keycode and timestamp.
static bool held[256] = {};
static Time release_time[256] = {};
static unsigned int current_key;
static bool repeated_press = false;
static GdkFilterReturn observe_key(GdkXEvent* raw, GdkEvent*, gpointer) {
  const auto* event = static_cast<XEvent*>(raw);
  if (event->type != KeyPress && event->type != KeyRelease)
    return GDK_FILTER_CONTINUE;
  const auto key = event->xkey.keycode;
  if (key >= 256) return GDK_FILTER_CONTINUE;
  if (event->type == KeyRelease) {
    release_time[key] = held[key] ? event->xkey.time : 0;
    held[key] = false;
  } else {
    current_key = key;
    repeated_press = held[key] ||
        (release_time[key] != 0 && release_time[key] == event->xkey.time);
  }
  return GDK_FILTER_CONTINUE;
}

void handle_key_down(const char* keystring, void* user_data) {
  held[current_key] = true;
  if (repeated_press) return;
  const char* identifier;

  std::string val = keystring;
  auto result = std::find_if(hotkey_id_map.begin(), hotkey_id_map.end(),
                             [val](const auto& e) { return e.second == val; });

  if (result == hotkey_id_map.end()) return;
  identifier = result->first.c_str();

  g_autoptr(FlValue) event_data = fl_value_new_map();
  fl_value_set_string_take(event_data, "identifier",
                           fl_value_new_string(identifier));

  FlValue* event = fl_value_new_map();
  fl_value_set_string_take(event, "type", fl_value_new_string("onKeyDown"));
  fl_value_set_string_take(event, "data", event_data);

  fl_event_channel_send(event_channel, event, nullptr, nullptr);
}

guint get_mods(const std::vector<std::string>& modifiers) {
  guint mods = 0;
  for (int i = 0; i < modifiers.size(); i++) {
    guint mod = 0;
    if (modifiers[i] == "alt")
      mod = GDK_MOD1_MASK;
    else if (modifiers[i] == "capsLock")
      mod = GDK_LOCK_MASK;
    else if (modifiers[i] == "control")
      mod = GDK_CONTROL_MASK;
    else if (modifiers[i] == "meta")
      mod = GDK_META_MASK;
    else if (modifiers[i] == "shift")
      mod = GDK_SHIFT_MASK;
    mods = mods | mod;
  }
  return mods;
}

static FlMethodResponse* hkm_register(_HotkeyManagerLinuxPlugin* self,
                                      FlValue* args) {
  FlValue* modifiers_value = fl_value_lookup_string(args, "modifiers");

  const char* identifier =
      fl_value_get_string(fl_value_lookup_string(args, "identifier"));
  const int key_code =
      fl_value_get_int(fl_value_lookup_string(args, "keyCode"));
  std::vector<std::string> modifiers;
  for (gint i = 0; i < fl_value_get_length(modifiers_value); i++) {
    std::string keyModifier =
        fl_value_get_string(fl_value_get_list_value(modifiers_value, i));
    modifiers.push_back(keyModifier);
  }

  g_autofree gchar* keystring =
      gtk_accelerator_name(key_code, (GdkModifierType)get_mods(modifiers));

  keybinder_init();
  if (!keybinder_bind(keystring, handle_key_down, NULL)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "registration_failed", "The global shortcut is unavailable", nullptr));
  }
  hotkey_id_map.insert(
      std::pair<std::string, std::string>(identifier, keystring));


  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* hkm_unregister(_HotkeyManagerLinuxPlugin* self,
                                        FlValue* args) {
  const char* identifier =
      fl_value_get_string(fl_value_lookup_string(args, "identifier"));
  auto result = hotkey_id_map.find(identifier);
  if (result != hotkey_id_map.end()) {
    keybinder_unbind(result->second.c_str(), handle_key_down);
    hotkey_id_map.erase(result);
  }

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* hkm_unregister_all(_HotkeyManagerLinuxPlugin* self,
                                            FlValue* args) {
  for (std::map<std::string, std::string>::iterator it = hotkey_id_map.begin();
       it != hotkey_id_map.end(); ++it) {
    std::string identifier = it->first;
    const char* keystring = it->second.c_str();
    keybinder_unbind(keystring, handle_key_down);
  }

  hotkey_id_map.clear();

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

// Called when a method call is received from Flutter.
static void hotkey_manager_linux_plugin_handle_method_call(
    HotkeyManagerLinuxPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "register") == 0) {
    response = hkm_register(self, args);
  } else if (strcmp(method, "unregister") == 0) {
    response = hkm_unregister(self, args);
  } else if (strcmp(method, "unregisterAll") == 0) {
    response = hkm_unregister_all(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void hotkey_manager_linux_plugin_dispose(GObject* object) {
  gdk_window_remove_filter(nullptr, observe_key, nullptr);
  g_clear_object(&event_channel);
  G_OBJECT_CLASS(hotkey_manager_linux_plugin_parent_class)->dispose(object);
}

static void hotkey_manager_linux_plugin_class_init(
    HotkeyManagerLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = hotkey_manager_linux_plugin_dispose;
}

static void hotkey_manager_linux_plugin_init(HotkeyManagerLinuxPlugin* self) {
  gdk_window_add_filter(nullptr, observe_key, nullptr);
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  HotkeyManagerLinuxPlugin* plugin = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  hotkey_manager_linux_plugin_handle_method_call(plugin, method_call);
}

void hotkey_manager_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  HotkeyManagerLinuxPlugin* plugin = HOTKEY_MANAGER_LINUX_PLUGIN(
      g_object_new(hotkey_manager_linux_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "dev.leanflutter.plugins/hotkey_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
  event_channel =
      fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           "dev.leanflutter.plugins/hotkey_manager_event",
                           FL_METHOD_CODEC(event_codec));

  g_object_unref(plugin);
}
