#ifndef GHOSTCOPY_LINK_HANDLER_ICON_H_
#define GHOSTCOPY_LINK_HANDLER_ICON_H_

#include <gtk/gtk.h>

// png is borrowed for the duration of the callback. Loading and SVG rendering
// happen asynchronously; callers invoke this on GTK's main thread.
using LinkIconCallback = void (*)(GBytes* png, gpointer data);
void load_link_handler_icon(GtkIconTheme* theme, GIcon* icon,
                            LinkIconCallback callback, gpointer data);

#endif
