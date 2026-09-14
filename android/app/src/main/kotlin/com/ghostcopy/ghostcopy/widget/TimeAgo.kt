package com.ghostcopy.ghostcopy.widget

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Relative timestamps for the home screen widget.
 *
 * One ladder, shared by the widget and its list factory. It previously existed
 * twice in this package, differing only in how the input was obtained, which is
 * the kind of duplication that drifts: the two could disagree about when a clip
 * stops being "Just now".
 *
 * The formatters are held here rather than constructed per call. `getViewAt`
 * runs once per visible row on every bind, and building a `SimpleDateFormat`
 * sets up a locale, a calendar and a timezone each time.
 */
internal object TimeAgo {

  /**
   * Parses the UTC instant Dart sends as `...T12:00:00.000Z`.
   *
   * Locale.US and an explicit UTC zone, both deliberately. Parsing with the
   * default timezone interpreted those digits as LOCAL time, so every clip was
   * off by the device's UTC offset: east of UTC a clip copied a second ago read
   * as hours old, and west of UTC every clip read as "Just now" because the
   * difference came out negative. Locale.US because this is a fixed machine
   * format; a locale with non-Latin digits must not be applied to it.
   */
  private val isoParser: SimpleDateFormat =
    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply {
      timeZone = TimeZone.getTimeZone("UTC")
    }

  /** Display format stays localized - only the parse above is fixed. */
  private val dayFormat: SimpleDateFormat =
    SimpleDateFormat("MMM d", Locale.getDefault())

  /** Relative time for an epoch-millisecond timestamp. */
  fun format(timestampMs: Long): String {
    if (timestampMs == 0L) return "Never"

    val diffMs = System.currentTimeMillis() - timestampMs

    return when {
      diffMs < 1000 -> "Just now"
      diffMs < 60_000 -> "${diffMs / 1000}s ago"
      diffMs < 3_600_000 -> "${diffMs / 60_000}m ago"
      diffMs < 86_400_000 -> "${diffMs / 3_600_000}h ago"
      else -> synchronized(dayFormat) { dayFormat.format(Date(timestampMs)) }
    }
  }

  /**
   * Relative time for an ISO 8601 instant, or null when it cannot be parsed.
   */
  fun formatIso(isoString: String): String? {
    val date = synchronized(isoParser) {
      try {
        isoParser.parse(isoString)
      } catch (e: java.text.ParseException) {
        null
      }
    } ?: return null
    return format(date.time)
  }
}
