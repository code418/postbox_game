package com.code418.postbox_game.wear

import android.content.Context
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Reads the snapshot `HomeWidgetService` (Dart) writes, and applies the
 * London-date freshness rules on top.
 *
 * The bridge is the `home_widget` plugin's own SharedPreferences store, which
 * it exposes via [HomeWidgetPlugin.getData] — the same store the phone's
 * home-screen widget reads. That means the tile and complications need no
 * Firebase, no network and no Flutter engine: they render whatever the app
 * last knew, which on a watch is exactly the right trade.
 *
 * KEY VALUES MUST MATCH `HomeWidgetService.key*` in
 * `lib/services/home_widget_service.dart` exactly. The plugin bridges the two
 * sides purely by string, so a rename on either side fails silently as zeros
 * rather than as a compile error. `test/cross_language_sync_test.dart` pins
 * them against each other.
 */
object WearPrefs {
    const val KEY_SIGNED_IN = "signedIn"
    const val KEY_STREAK = "streak"
    const val KEY_TODAY_POINTS = "todayPoints"
    const val KEY_BOXES_FOUND = "boxesFound"
    const val KEY_LIFETIME_POINTS = "lifetimePoints"
    const val KEY_DAILY_DATE = "dailyDate"
    const val KEY_LAST_CLAIM_DATE = "lastClaimDate"

    /**
     * Current stats for display. [today] is injectable so the freshness
     * boundary can be pinned in a test.
     */
    fun read(context: Context, today: String = londonToday()): WearStats {
        val prefs = HomeWidgetPlugin.getData(context)
        if (!prefs.getBoolean(KEY_SIGNED_IN, false)) {
            return WearStats(
                signedIn = false,
                streak = 0,
                todayPoints = 0,
                lifetimePoints = 0,
                boxesFound = 0,
            )
        }
        val dailyDate = prefs.getString(KEY_DAILY_DATE, null)
        val lastClaimDate = prefs.getString(KEY_LAST_CLAIM_DATE, null)
        return WearStats(
            signedIn = true,
            streak = freshStreak(
                stored = prefs.getInt(KEY_STREAK, 0),
                lastClaimDate = lastClaimDate,
                today = today,
                yesterday = londonYesterday(today),
            ),
            todayPoints = freshTodayPoints(
                stored = prefs.getInt(KEY_TODAY_POINTS, 0),
                dailyDate = dailyDate,
                lastClaimDate = lastClaimDate,
                today = today,
            ),
            lifetimePoints = prefs.getInt(KEY_LIFETIME_POINTS, 0),
            boxesFound = prefs.getInt(KEY_BOXES_FOUND, 0),
        )
    }
}
