package com.ghostcopy.ghostcopy.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews
import com.ghostcopy.ghostcopy.IntentAuth
import com.ghostcopy.ghostcopy.R

/**
 * App Widget Provider for clipboard synchronization.
 *
 * Displays the 5 most recent clipboard items on home screen.
 * Updates when the app writes new data and when a notification arrives. There
 * is no refresh button: it scheduled a worker whose callFlutterRefresh() only
 * logged and returned true, so it re-drew the same rows from SharedPreferences
 * and nothing else.
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

      // Set up item click template (will be filled in by RemoteViewsFactory).
      //
      // A broadcast, not an activity: copying a text clip needs a clipboard
      // write and nothing else, and routing every tap through MainActivity
      // dragged the whole app to the foreground to do it.
      //
      // FLAG_MUTABLE, not FLAG_IMMUTABLE. A collection template only receives
      // the per-row extras from setOnClickFillInIntent if it is mutable - an
      // immutable template drops them, which left clipboardId empty and made
      // every row tap a no-op. The receiver is not exported and the intent is
      // explicit, so the launcher can fire this but cannot redirect it.
      val itemClickIntent = Intent(context, WidgetCopyReceiver::class.java).apply {
        action = ACTION_WIDGET_ITEM_CLICK
        putExtra(IntentAuth.EXTRA_TOKEN, IntentAuth.token(context))
      }
      val itemClickPendingIntent = PendingIntent.getBroadcast(
        context,
        widgetId,
        itemClickIntent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
      )
      views.setPendingIntentTemplate(R.id.widget_list, itemClickPendingIntent)

      // Update last updated timestamp
      val lastUpdated = WidgetDataManager.getInstance(context).getLastUpdated()
      views.setTextViewText(R.id.last_updated_text, TimeAgo.format(lastUpdated))

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
      AppWidgetManager.ACTION_APPWIDGET_UPDATE -> {
        Log.d(TAG, "📢 Widget update broadcast received")
        notifyWidgetDataChanged(context)
      }
    }
  }

  companion object {
    private const val TAG = "ClipboardWidget"
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
