#ifndef GHOSTCOPY_CLIPBOARD_CHANGE_CHANNEL_H_
#define GHOSTCOPY_CLIPBOARD_CHANGE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Lifetime follows the Flutter view; no clipboard payload crosses this channel.
void register_clipboard_change_channel(FlView* view);

#endif
