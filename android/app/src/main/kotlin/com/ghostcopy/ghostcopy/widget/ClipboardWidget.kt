package com.ghostcopy.ghostcopy.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews
import com.ghostcopy.ghostcopy.MainActivity
import com.ghostcopy.ghostcopy.R
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * App Widget Provider for clipboard synchronization.
 *
 * Displays the 5 most recent clipboard items on home screen.
 * Updates via:
 * - Manual refresh button (WorkManager task)
 * - FCM notifications (triggered by backend)
 * - App lifecycle events (synced by Flutter)
 *
 * Memory Management:
 * - Does not hold clipboard data in memory
 * - Uses RemoteViews for efficient ListView rendering
 * - Releases widget references after update
 */
class ClipboardWidget : AppWidgetProvider() {

  override fun onUpdate(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetIds: IntArray,
  ) {
    Log.d(TAG, "onUpdate called with ${appWidgetIds.size} widgets")
    appWidgetIds.forEach { widgetId ->
      updateWidget(context, appWidgetManager, widgetId)
    }
  }

  /**
   * Update a single widget instance.
   */
  private fun updateWidget(
    context: Context,
    appWidgetManager: AppWidgetManager,
    widgetId: Int,
  ) {
    try {
      val views = RemoteViews(context.packageName, R.layout.widget_layout)

      // Set up ListView adapter using RemoteViewsService
      val intent = Intent(context, ClipboardWidgetService::class.java)
      views.setRemoteAdapter(R.id.widget_list, intent)

      // Set up refresh button click
      val refreshIntent = Intent(context, ClipboardWidget::class.java).apply {
        action = ACTION_REFRESH
      }
      val refreshPendingIntent = PendingIntent.getBroadcast(
        context,
        widgetId, // Use widget ID as request code for uniqueness
        refreshIntent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
      views.setOnClickPendingIntent(R.id.refresh_button, refreshPendingIntent)

      // Set up item click template (will be filled in by RemoteViewsFactory)
      val itemClickIntent = Intent(context, MainActivity::class.java).apply {
        action = ACTION_WIDGET_ITEM_CLICK
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
      }
      val itemClickPendingIntent = PendingIntent.getActivity(
        context,
        widgetId,
        itemClickIntent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
      views.setPendingIntentTemplate(R.id.widget_list, itemClickPendingIntent)

      // Update last updated timestamp
      val lastUpdated = WidgetDataManager.getInstance(context).getLastUpdated()
      views.setTextViewText(R.id.last_updated_text, formatTimeAgo(lastUpdated))

      // Update the widget
      appWidgetManager.updateAppWidget(widgetId, views)
      Log.d(TAG, "✅ Updated widget $widgetId")
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to update widget: ${e.message}", e)
    }
  }

  override fun onReceive(context: Context, intent: Intent) {
    super.onReceive(context, intent)

    when (intent.action) {
      ACTION_REFRESH -> {
        Log.d(TAG, "🔄 Refresh button tapped")
        handleRefreshAction(context)
      }
      AppWidgetManager.ACTION_APPWIDGET_UPDATE -> {
        Log.d(TAG, "📢 Widget update broadcast received")
        notifyWidgetDataChanged(context)
      }
    }
  }

  /**
   * Handle manual refresh button tap.
   *
   * Triggers WorkManager task to fetch latest data from Supabase.
   */
  private fun handleRefreshAction(context: Context) {
    try {
      // Enqueue WorkManager task to fetch data
      // This will call Flutter's WidgetService.refreshWidget()
      WidgetRefreshWorker.scheduleRefresh(context)
      Log.d(TAG, "✅ Scheduled widget refresh task")
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to schedule refresh: ${e.message}", e)
    }
  }



  /**
   * Format timestamp as relative time (e.g., "2m ago", "Just now").
   */
  private fun formatTimeAgo(timestampMs: Long): String {
    if (timestampMs == 0L) return "Never"

    val now = System.currentTimeMillis()
    val diffMs = now - timestampMs

    return when {
      diffMs < 1000 -> "Just now"
      diffMs < 60_000 -> "${diffMs / 1000}s ago"
      diffMs < 3_600_000 -> "${diffMs / 60_000}m ago"
      diffMs < 86_400_000 -> "${diffMs / 3_600_000}h ago"
      else -> {
        // Format as date for older items
        val sdf = SimpleDateFormat("MMM d", Locale.getDefault())
        sdf.format(Date(timestampMs))
      }
    }
  }

  companion object {
    private const val TAG = "ClipboardWidget"
    private const val ACTION_REFRESH = "com.ghostcopy.ghostcopy.WIDGET_REFRESH"
    private const val ACTION_WIDGET_ITEM_CLICK = "com.ghostcopy.ghostcopy.WIDGET_ITEM_CLICK"

    /**
     * Notify widget that data has changed (e.g., from FCM notification).
     *
     * Triggers ListView to reload data from RemoteViewsFactory.
     */
    fun notifyWidgetDataChanged(context: Context) {
      try {
        val appWidgetManager = AppWidgetManager.getInstance(context)
        val componentName = ComponentName(context, ClipboardWidget::class.java)
        val widgetIds = appWidgetManager.getAppWidgetIds(componentName)

        if (widgetIds.isNotEmpty()) {
          appWidgetManager.notifyAppWidgetViewDataChanged(widgetIds, R.id.widget_list)
          Log.d(TAG, "✅ Notified widget ListView to refresh (${widgetIds.size} widgets)")
        }
      } catch (e: Exception) {
        Log.e(TAG, "❌ Failed to notify widget data change: ${e.message}", e)
      }
    }
  }
}
