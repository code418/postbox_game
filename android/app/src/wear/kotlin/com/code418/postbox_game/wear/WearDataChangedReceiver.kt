package com.code418.postbox_game.wear

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester

/**
 * Nudges the tile and complications to re-read after the app writes new stats.
 *
 * Dart reaches this through `HomeWidget.updateWidget(qualifiedAndroidName:)`,
 * which sends an EXPLICIT broadcast to the named class — explicit broadcasts
 * are exempt from the Android 8+ implicit-broadcast restrictions, so no
 * intent-filter is needed and the receiver stays unexported.
 *
 * Strictly an optimisation. `updateWidget` asks AppWidgetManager for the
 * component's widget ids before broadcasting and Wear OS has no launcher
 * widgets, so this may never fire on some devices; the tile's freshness
 * interval and enter-event re-read cover that. Treat a missed push as latency,
 * never as staleness that matters.
 */
class WearDataChangedReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        TileService.getUpdater(context)
            .requestUpdate(PostboxTileService::class.java)

        val requester = ComplicationDataSourceUpdateRequester.create(
            context,
            ComponentName(context, StreakComplicationService::class.java),
        )
        requester.requestUpdateAll()

        ComplicationDataSourceUpdateRequester.create(
            context,
            ComponentName(context, TodayPointsComplicationService::class.java),
        ).requestUpdateAll()
    }
}
