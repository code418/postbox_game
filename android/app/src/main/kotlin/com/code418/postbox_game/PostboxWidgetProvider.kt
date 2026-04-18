package com.code418.postbox_game

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Renders the "Postbox Claim" home-screen widget.
 *
 * Data is written by `HomeWidgetService` on the Flutter side via the
 * `home_widget` package (keys must match the constants in
 * `lib/services/home_widget_service.dart`). Tapping anywhere on the widget
 * deep-links into MainActivity with `postbox://claim?source=widget`, which
 * `main.dart` resolves to the Claim tab with an auto-triggered scan.
 */
class PostboxWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: android.appwidget.AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val signedIn = widgetData.getBoolean(KEY_SIGNED_IN, false)
        val streak = widgetData.getInt(KEY_STREAK, 0)
        val todayPoints = widgetData.getInt(KEY_TODAY_POINTS, 0)
        val weekPoints = widgetData.getInt(KEY_WEEK_POINTS, 0)
        val boxesFound = widgetData.getInt(KEY_BOXES_FOUND, 0)
        val lifetimePoints = widgetData.getInt(KEY_LIFETIME_POINTS, 0)

        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.postbox_widget)

            if (signedIn) {
                views.setViewVisibility(R.id.widget_stats_row, View.VISIBLE)
                views.setViewVisibility(R.id.widget_signed_out, View.GONE)
                views.setViewVisibility(R.id.widget_streak, View.VISIBLE)
                views.setTextViewText(R.id.widget_streak, "🔥 $streak")
                views.setTextViewText(R.id.widget_today, todayPoints.toString())
                views.setTextViewText(R.id.widget_week, weekPoints.toString())
                views.setTextViewText(R.id.widget_boxes, boxesFound.toString())
                views.setTextViewText(R.id.widget_lifetime, lifetimePoints.toString())
                views.setTextViewText(R.id.widget_cta, context.getString(R.string.widget_cta_claim))
            } else {
                views.setViewVisibility(R.id.widget_stats_row, View.GONE)
                views.setViewVisibility(R.id.widget_signed_out, View.VISIBLE)
                views.setViewVisibility(R.id.widget_streak, View.GONE)
                views.setTextViewText(R.id.widget_cta, context.getString(R.string.widget_cta_sign_in))
            }

            val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse(DEEP_LINK),
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            views.setOnClickPendingIntent(R.id.widget_cta, pendingIntent)

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    companion object {
        private const val KEY_SIGNED_IN = "signedIn"
        private const val KEY_STREAK = "streak"
        private const val KEY_TODAY_POINTS = "todayPoints"
        private const val KEY_WEEK_POINTS = "weekPoints"
        private const val KEY_BOXES_FOUND = "boxesFound"
        private const val KEY_LIFETIME_POINTS = "lifetimePoints"
        private const val DEEP_LINK = "postbox://claim?source=widget"
    }
}
