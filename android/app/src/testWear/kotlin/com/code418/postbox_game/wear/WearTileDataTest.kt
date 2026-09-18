package com.code418.postbox_game.wear

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * The Wear tile and complications have no UI test, and they render from a
 * SharedPreferences snapshot that can be a day stale. These pin the freshness
 * rules that stop them presenting yesterday's numbers as today's, and they are
 * the drift guard against the Dart originals (`freshStreak` in
 * lib/streak_service.dart, the dailyDate fallback in HomeWidgetService).
 */
class WearTileDataTest {

    // ── londonToday / londonYesterday ────────────────────────────────────

    @Test
    fun `londonToday follows the London day, not UTC`() {
        // 23:30 UTC on 30 June is 00:30 on 1 July in London (BST, UTC+1).
        // A naive UTC date would report the wrong day for half an hour every
        // summer evening.
        assertEquals(
            "2026-07-01",
            londonToday(Instant.parse("2026-06-30T23:30:00Z")),
        )
    }

    @Test
    fun `londonToday matches UTC in winter`() {
        // 23:30 UTC on 31 December is still 31 December in London (GMT).
        assertEquals(
            "2026-12-31",
            londonToday(Instant.parse("2026-12-31T23:30:00Z")),
        )
    }

    @Test
    fun `londonToday honours an injected zone`() {
        assertEquals(
            "2026-06-30",
            londonToday(Instant.parse("2026-06-30T23:30:00Z"), ZoneId.of("UTC")),
        )
    }

    @Test
    fun `londonYesterday crosses a month and a year boundary`() {
        assertEquals("2026-06-30", londonYesterday("2026-07-01"))
        assertEquals("2025-12-31", londonYesterday("2026-01-01"))
        // And a leap day.
        assertEquals("2028-02-29", londonYesterday("2028-03-01"))
    }

    // ── freshTodayPoints ─────────────────────────────────────────────────

    @Test
    fun `points from today are shown`() {
        assertEquals(27, freshTodayPoints(27, "2026-09-18", null, "2026-09-18"))
    }

    @Test
    fun `points from an earlier day are zeroed`() {
        // The whole reason the dates are written: dailyPoints is never reset
        // server-side, so a tile rendered the next morning would otherwise
        // still show yesterday's score.
        assertEquals(0, freshTodayPoints(27, "2026-09-17", null, "2026-09-18"))
    }

    @Test
    fun `falls back to lastClaimDate when dailyDate is absent`() {
        // Accounts that last claimed before dailyDate existed.
        assertEquals(27, freshTodayPoints(27, null, "2026-09-18", "2026-09-18"))
        assertEquals(0, freshTodayPoints(27, null, "2026-09-17", "2026-09-18"))
    }

    @Test
    fun `dailyDate wins over a stale lastClaimDate`() {
        // The two are written by separate transactions with a brief ordering
        // window; dailyDate is the one written alongside the points.
        assertEquals(
            27,
            freshTodayPoints(27, "2026-09-18", "2026-09-17", "2026-09-18"),
        )
    }

    @Test
    fun `blank dates are treated as missing, not as a date`() {
        // HomeWidgetService writes "" rather than omitting the key, because
        // the plugin's store has no null. A blank must not compare equal to
        // anything and must not crash.
        assertEquals(0, freshTodayPoints(27, "", "", "2026-09-18"))
    }

    // ── freshStreak ──────────────────────────────────────────────────────

    @Test
    fun `a streak claimed today or yesterday still stands`() {
        assertEquals(5, freshStreak(5, "2026-09-18", "2026-09-18", "2026-09-17"))
        assertEquals(5, freshStreak(5, "2026-09-17", "2026-09-18", "2026-09-17"))
    }

    @Test
    fun `a broken streak reads zero`() {
        assertEquals(0, freshStreak(5, "2026-09-16", "2026-09-18", "2026-09-17"))
    }

    @Test
    fun `no stored streak and no claim date read zero`() {
        assertEquals(0, freshStreak(0, "2026-09-18", "2026-09-18", "2026-09-17"))
        assertEquals(0, freshStreak(5, null, "2026-09-18", "2026-09-17"))
        assertEquals(0, freshStreak(5, "", "2026-09-18", "2026-09-17"))
    }

    // ── labels ───────────────────────────────────────────────────────────

    @Test
    fun `streak label reads naturally at the edges`() {
        assertEquals("No streak", streakLabel(0))
        assertEquals("No streak", streakLabel(-1))
        assertEquals("1 day streak", streakLabel(1))
        assertEquals("12 day streak", streakLabel(12))
    }

    @Test
    fun `next milestone is the next one actually ahead`() {
        assertEquals(7, nextStreakMilestone(0))
        assertEquals(7, nextStreakMilestone(6))
        assertEquals(30, nextStreakMilestone(7))
        assertEquals(100, nextStreakMilestone(30))
        assertEquals(365, nextStreakMilestone(100))
        // Past a year the arc keeps moving rather than sitting full forever.
        assertEquals(730, nextStreakMilestone(365))
        assertEquals(730, nextStreakMilestone(400))
    }

    @Test
    fun `milestone is always strictly greater than the streak`() {
        // Otherwise a RANGED_VALUE complication would be handed value == max
        // (a permanently full arc) or, worse, value > max.
        for (streak in 0..800) {
            assert(nextStreakMilestone(streak) > streak) {
                "milestone ${nextStreakMilestone(streak)} !> streak $streak"
            }
        }
    }

    @Test
    fun `points label abbreviates rather than overflowing the slot`() {
        // Complication short text is capped at 7 characters by the system.
        assertEquals("0", pointsLabel(0))
        assertEquals("9999", pointsLabel(9999))
        assertEquals("10k", pointsLabel(10_000))
        assertEquals("12.3k", pointsLabel(12_345))
        assertEquals("999.9k", pointsLabel(999_999))
        assertEquals("1M", pointsLabel(1_000_000))
    }

    @Test
    fun `every points label fits a complication short text slot`() {
        for (points in intArrayOf(0, 7, 99, 1234, 9999, 10_000, 87_654, 999_999, 5_000_000)) {
            assert(pointsLabel(points).length <= 7) {
                "pointsLabel($points) = '${pointsLabel(points)}' is too long"
            }
        }
    }
}
