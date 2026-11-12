#include "link_handler_icon.h"

#include <glib/gstdio.h>
#include <string>

namespace {
void Write(const std::string& root, const std::string& file, const char* text) {
  const std::string location = root + "/" + file;
  g_autofree gchar* parent = g_path_get_dirname(location.c_str());
  g_assert_cmpint(g_mkdir_with_parents(parent, 0700), ==, 0);
  g_assert_true(g_file_set_contents(location.c_str(), text, -1, nullptr));
}

struct Result {
  GMainLoop* loop;
  bool done = false;
  GBytes* png = nullptr;
};

void Loaded(GBytes* png, gpointer data) {
  auto* result = static_cast<Result*>(data);
  result->done = true;
  if (png) result->png = g_bytes_ref(png);
  g_main_loop_quit(result->loop);
}

void Check(GtkIconTheme* theme, const char* name, int red, int green, int blue) {
  g_autoptr(GIcon) icon = g_themed_icon_new(name);
  Result result{g_main_loop_new(nullptr, FALSE)};
  load_link_handler_icon(theme, icon, Loaded, &result);
  if (!result.done) g_main_loop_run(result.loop);
  g_assert_nonnull(result.png);
  g_autoptr(GInputStream) stream = g_memory_input_stream_new_from_bytes(result.png);
  g_autoptr(GdkPixbuf) pixels = gdk_pixbuf_new_from_stream(stream, nullptr, nullptr);
  g_assert_nonnull(pixels);
  const guchar* first = gdk_pixbuf_get_pixels(pixels);
  g_assert_cmpint(first[0], ==, red);
  g_assert_cmpint(first[1], ==, green);
  g_assert_cmpint(first[2], ==, blue);
  g_bytes_unref(result.png);
  g_main_loop_unref(result.loop);
}
}  // namespace

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  g_timeout_add_seconds(10, +[](gpointer) -> gboolean {
    g_error("Timed out loading themed link icons");
    return G_SOURCE_REMOVE;
  }, nullptr);
  g_autofree gchar* directory = g_dir_make_tmp("ghostcopy-icon-theme-XXXXXX", nullptr);
  g_assert_nonnull(directory);
  const std::string root(directory);
  Write(root, "Selected/index.theme",
        "[Icon Theme]\nName=Selected\nInherits=Parent\nDirectories=64x64/apps\n"
        "[64x64/apps]\nSize=64\nType=Fixed\nContext=Applications\n");
  Write(root, "Parent/index.theme",
        "[Icon Theme]\nName=Parent\nDirectories=64x64/apps\n"
        "[64x64/apps]\nSize=64\nType=Fixed\nContext=Applications\n");
  Write(root, "hicolor/index.theme",
        "[Icon Theme]\nName=Hicolor\nDirectories=64x64/apps\n"
        "[64x64/apps]\nSize=64\nType=Fixed\nContext=Applications\n");
  const char* red = "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>"
                    "<rect width='64' height='64' fill='#ff0000'/></svg>";
  const char* green = "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>"
                      "<rect width='64' height='64' fill='#00ff00'/></svg>";
  const char* blue = "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>"
                     "<rect width='64' height='64' fill='#0000ff'/></svg>";
  Write(root, "hicolor/64x64/apps/browser.svg", red);
  Write(root, "Selected/64x64/apps/browser.svg", green);
  Write(root, "Parent/64x64/apps/mail.svg", blue);
  g_autoptr(GtkIconTheme) theme = gtk_icon_theme_new();
  const gchar* search[] = {directory};
  gtk_icon_theme_set_search_path(theme, search, 1);
  gtk_icon_theme_set_custom_theme(theme, "Selected");
  Check(theme, "browser", 0, 255, 0);
  Check(theme, "mail", 0, 0, 255);
  return 0;
}
