#include "my_application.h"

int main(int argc, char** argv) {
  // window_manager/screen_retriever use X11 window positioning. Keep that
  // backend on Plasma Wayland; clipboard reads and global shortcuts use
  // native Wayland data-control and portals independently of the GTK backend.
  gdk_set_allowed_backends("x11");
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
