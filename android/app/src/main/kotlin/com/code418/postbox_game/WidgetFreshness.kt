package com.code418.postbox_game

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/*
 * London-date freshness rules for every glanceable surface that renders from
 * the snapshot `HomeWidgetService` (Dart) writes: the phone home-screen widget
 * and, in the wear flavour, the Tile and complications.
 *
 * They MIRROR Dart: `freshStreak` in `lib/streak_service.dart` and the
 * `dailyDate`/`lastClaimDate`/`weekStart` checks in `HomeWidgetService.refresh`.
 * They have to be applied a second time, natively, because Dart date-checks
 * only at WRITE time, while these surfaces redraw whenever the system asks:
 * a day after that write if the app hasn't been opened since.
 *
 * Deliberately free of Android imports so they can be unit-tested on the JVM.
 */

/** The game's day boundary. The server writes every date in this zone. */
val LONDON: ZoneId = ZoneId.of("Europe/London")

/** Today in Europe/London as `YYYY-MM-DD`, matching the stored date strings. */
fun londonToday(now: Instant = Instant.now(), zone: ZoneId = LONDON): String =
    now.atZone(zone).toLocalDate().toString()

/** The day before [today] (`YYYY-MM-DD` in, `YYYY-MM-DD` out). */
fun londonYesterday(today: String): String =
    LocalDate.parse(today).minusDays(1).toString()

/** The Monday starting [today]'s week. Mirrors `weekStartLondon` (Dart) and
 *  `getWeekStart` (functions/src/_leaderboardUtils.ts). */
fun londonWeekStart(today: String): String =
    LocalDate.parse(today)
        .with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
        .toString()

/**
 * Blank is how a missing date reaches us: `HomeWidgetService` writes `""`
 * rather than omitting the key, because the plugin's store has no null.
 */
private fun String?.orNullIfBlank(): String? = if (isNullOrBlank()) null else this

/**
 * Today's points, or 0 if the stored value belongs to an earlier day.
 *
 * `dailyPoints` is never reset server-side (see startScoring's lifetime
 * transaction), so the stored number reflects whichever day's claim last
 * touched it. `dailyDate` is written in that same transaction; `lastClaimDate`
 * comes from a separate streak transaction, so it is only the fallback for
 * accounts that last claimed before `dailyDate` existed.
 */
fun freshTodayPoints(
    stored: Int,
    dailyDate: String?,
    lastClaimDate: String?,
    today: String,
): Int {
    val daily = dailyDate.orNullIfBlank()
    val last = lastClaimDate.orNullIfBlank()
    val fresh = if (daily != null) daily == today else last == today
    return if (fresh) stored else 0
}

/**
 * This week's points, or 0 once [weekStart] (the Monday of the week the
 * stored value belongs to) is not the current London week. `weeklyPoints`,
 * like `dailyPoints`, is only rewritten by a claim. A blank [weekStart] also
 * reads 0: Dart writes blank exactly when it already zeroed the value.
 */
fun freshWeekPoints(stored: Int, weekStart: String?, today: String): Int =
    if (weekStart.orNullIfBlank() == londonWeekStart(today)) stored else 0

/**
 * The streak to show, or 0 once it is broken.
 *
 * The server only rewrites `streak` on a claim, so a user who missed yesterday
 * would otherwise keep seeing their old streak until they claimed again: the
 * surface would be quietly lying about the thing it exists to show.
 */
fun freshStreak(
    stored: Int,
    lastClaimDate: String?,
    today: String,
    yesterday: String,
): Int {
    if (stored <= 0) return 0
    val last = lastClaimDate.orNullIfBlank() ?: return 0
    return if (last == today || last == yesterday) stored else 0
}
