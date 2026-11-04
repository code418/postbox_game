package com.code418.postbox_game

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

/**
 * The phone widget redraws hourly without the app running, so it re-checks
 * the snapshot's dates natively. The daily/streak rules are pinned in the
 * wear flavour's WearTileDataTest (they are shared); these cover the weekly
 * rule the phone widget adds. Mirrors `weekStartLondon` in
 * lib/london_date.dart.
 */
class WidgetFreshnessTest {

    @Test
    fun `londonWeekStart is the Monday of the week`() {
        assertEquals("2026-09-21", londonWeekStart("2026-09-21")) // Monday
        assertEquals("2026-09-21", londonWeekStart("2026-09-25")) // Friday
        assertEquals("2026-09-21", londonWeekStart("2026-09-27")) // Sunday
        assertEquals("2025-12-29", londonWeekStart("2026-01-02")) // across a year
    }

    @Test
    fun `week points survive the week they belong to`() {
        assertEquals(84, freshWeekPoints(84, "2026-09-21", "2026-09-27"))
    }

    @Test
    fun `week points read 0 from the next Monday`() {
        assertEquals(0, freshWeekPoints(84, "2026-09-21", "2026-09-28"))
    }

    @Test
    fun `a blank or missing week start reads 0`() {
        assertEquals(0, freshWeekPoints(84, "", "2026-09-25"))
        assertEquals(0, freshWeekPoints(84, null, "2026-09-25"))
    }

    @Test
    fun `the widget's today follows London, not UTC`() {
        // 23:30 UTC on a summer Sunday is already Monday in London, so last
        // week's points must drop off.
        val today = londonToday(Instant.parse("2026-09-27T23:30:00Z"))
        assertEquals("2026-09-28", today)
        assertEquals(0, freshWeekPoints(84, "2026-09-21", today))
    }
}
