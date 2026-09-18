package com.code418.postbox_game.wear

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
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
        // applicationContext, NOT the receiver's context. TileService's updater
        // binds to the SysUI tile service internally, and the Context handed to
        // onReceive is a ReceiverRestrictedContext, which throws
        // ReceiverCallNotAllowedException ("BroadcastReceiver components are
        // not allowed to bind to services") on bindService. Unhandled on the
        // main thread, that killed the whole app process — so every refresh,
        // including the one right after a claim, took the app down with it.
        val appContext = context.applicationContext

        // And belt-and-braces: this push is an optimisation, so no failure of
        // it may ever reach the user. The tile's freshness interval and its
        // re-read on enter are the real guarantees.
        runCatching {
            TileService.getUpdater(appContext)
                .requestUpdate(PostboxTileService::class.java)
        }.onFailure { Log.w(TAG, "tile update request failed", it) }

        for (service in listOf(
            StreakComplicationService::class.java,
            TodayPointsComplicationService::class.java,
        )) {
            runCatching {
                ComplicationDataSourceUpdateRequester.create(
                    appContext,
                    ComponentName(appContext, service),
                ).requestUpdateAll()
            }.onFailure { Log.w(TAG, "complication update failed: $service", it) }
        }
    }

    private companion object {
        const val TAG = "WearDataChanged"
    }
}
