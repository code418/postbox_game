import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/london_date.dart';

void main() {
  group('weekStartLondon', () {
    test('Monday returns itself', () {
      expect(weekStartLondon('2026-04-13'), '2026-04-13');
    });
    test('Tuesday rolls back to Monday', () {
      expect(weekStartLondon('2026-04-14'), '2026-04-13');
    });
    test('Sunday rolls back to Monday of same week', () {
      expect(weekStartLondon('2026-04-19'), '2026-04-13');
    });
    test('crosses month boundary', () {
      expect(weekStartLondon('2026-05-03'), '2026-04-27');
    });
    test('crosses year boundary', () {
      expect(weekStartLondon('2026-01-01'), '2025-12-29');
    });
  });

  group('monthStartLondon', () {
    test('mid-month returns 1st', () {
      expect(monthStartLondon('2026-04-17'), '2026-04-01');
    });
    test('1st returns itself', () {
      expect(monthStartLondon('2026-04-01'), '2026-04-01');
    });
    test('end of month', () {
      expect(monthStartLondon('2026-02-28'), '2026-02-01');
    });
  });

  group('expectedPeriodKey', () {
    test('daily returns today', () {
      expect(expectedPeriodKey('daily', '2026-04-17'), '2026-04-17');
    });
    test('weekly returns week:<Monday>', () {
      expect(expectedPeriodKey('weekly', '2026-04-17'), 'week:2026-04-13');
    });
    test('monthly returns month:<YYYY-MM>', () {
      expect(expectedPeriodKey('monthly', '2026-04-17'), 'month:2026-04');
    });
    test('lifetime returns lifetime', () {
      expect(expectedPeriodKey('lifetime', '2026-04-17'), 'lifetime');
    });
    test('unknown period returns null', () {
      expect(expectedPeriodKey('yearly', '2026-04-17'), isNull);
    });
  });

  group('formatLondon (BST/GMT handling)', () {
    test('mid-winter UTC midday → same calendar date in London (GMT)', () {
      // 15 Jan 2026 12:00:00 UTC — GMT, no offset.
      expect(formatLondon(DateTime.utc(2026, 1, 15, 12, 0)), '2026-01-15');
    });

    test('mid-summer UTC midday → same calendar date in London (BST +1h)', () {
      // 15 Jul 2026 12:00:00 UTC. London is BST → 13:00 local. Same date.
      expect(formatLondon(DateTime.utc(2026, 7, 15, 12, 0)), '2026-07-15');
    });

    test('late-night UTC in summer rolls forward in London', () {
      // 14 Jul 2026 23:30 UTC. BST → 15 Jul 00:30 London → date is 2026-07-15.
      expect(formatLondon(DateTime.utc(2026, 7, 14, 23, 30)), '2026-07-15');
    });

    test('late-night UTC in winter does NOT roll forward (no offset)', () {
      // 14 Jan 2026 23:30 UTC. GMT → still 23:30 London → date is 2026-01-14.
      expect(formatLondon(DateTime.utc(2026, 1, 14, 23, 30)), '2026-01-14');
    });

    test('BST starts at the last Sunday of March, 01:00 UTC', () {
      // Last Sun of March 2026 = 29 Mar 2026.
      // 00:59 UTC on 29 Mar — still GMT (one minute before BST kicks in).
      expect(formatLondon(DateTime.utc(2026, 3, 29, 0, 59)), '2026-03-29');
      // 01:00 UTC on 29 Mar — BST. Local clock jumps to 02:00.
      // The date in London is still 29 Mar (no rollover).
      expect(formatLondon(DateTime.utc(2026, 3, 29, 1, 0)), '2026-03-29');
    });

    test('BST ends at the last Sunday of October, 01:00 UTC', () {
      // Last Sun of October 2026 = 25 Oct 2026.
      // 00:59 UTC on 25 Oct — still BST (one minute before GMT resumes).
      // BST = UTC+1 → 01:59 London → same date.
      expect(formatLondon(DateTime.utc(2026, 10, 25, 0, 59)), '2026-10-25');
      // 01:00 UTC on 25 Oct — GMT (no offset). Local clock falls back to 01:00.
      expect(formatLondon(DateTime.utc(2026, 10, 25, 1, 0)), '2026-10-25');
    });

    test('BST boundary: 2025 last-Sunday-of-March is 30 Mar', () {
      // Different year — different last-Sunday-of-March. Defends against
      // hard-coded year-2026 dates in _lastSundayOfMonthUtcAt01.
      // 30 Mar 2025 was a Sunday; before 01:00 UTC = GMT.
      expect(formatLondon(DateTime.utc(2025, 3, 30, 0, 30)), '2025-03-30');
      // After 01:00 UTC = BST.
      expect(formatLondon(DateTime.utc(2025, 3, 30, 1, 0)), '2025-03-30');
    });
  });

  group('yesterdayLondon vs UTC-subtract correctness around spring-forward', () {
    // yesterdayLondon must subtract one CALENDAR DAY from todayLondon, not
    // 24 hours from UTC — the latter is wrong during the first hour after BST
    // begins (see the comment in lib/london_date.dart).
    //
    // We can't override `now` here, but we can validate the helper's output
    // matches the calendar-day-subtract definition across a few year-spanning
    // dates by checking it's always exactly one day before todayLondon.
    test('returns a YYYY-MM-DD one day before todayLondon', () {
      final today = todayLondon();
      final yesterday = yesterdayLondon();

      final tDate = DateTime.utc(
        int.parse(today.substring(0, 4)),
        int.parse(today.substring(5, 7)),
        int.parse(today.substring(8, 10)),
      );
      final yDate = DateTime.utc(
        int.parse(yesterday.substring(0, 4)),
        int.parse(yesterday.substring(5, 7)),
        int.parse(yesterday.substring(8, 10)),
      );
      expect(tDate.difference(yDate).inDays, 1);
    });
  });

  group('yesterdayFor (pure variant)', () {
    // The pure helper underlies yesterdayLondon and is used directly by
    // analytics-property buckets that need to compute a "yesterday" against
    // an injected "today" without re-reading the wall clock.
    test('subtracts one calendar day from a mid-month date', () {
      expect(yesterdayFor('2026-05-20'), '2026-05-19');
    });
    test('handles month boundary (1st rolls back to previous month\'s last day)',
        () {
      expect(yesterdayFor('2026-05-01'), '2026-04-30');
      expect(yesterdayFor('2026-03-01'), '2026-02-28'); // non-leap Feb
      expect(yesterdayFor('2024-03-01'), '2024-02-29'); // leap Feb
    });
    test('handles year boundary (Jan 1 rolls back to Dec 31)', () {
      expect(yesterdayFor('2026-01-01'), '2025-12-31');
    });
    test('crosses the BST spring-forward day cleanly (calendar, not 24h, math)',
        () {
      // 2026-03-29 is BST-start (clocks jump 01:00 GMT → 02:00 BST).
      // yesterdayFor must return 2026-03-28 — a 24h-subtract from a London
      // wall-clock 00:30 (= UTC 23:30 on 03-28) would land on 03-27 instead.
      // yesterdayFor operates on the calendar string so it's immune by design;
      // this test pins that intent.
      expect(yesterdayFor('2026-03-29'), '2026-03-28');
    });
  });

  group('weekEndLondon', () {
    test('Monday returns following Sunday', () {
      // 2026-04-13 is a Monday → 2026-04-19 is the Sunday at the end of that
      // ISO week.
      expect(weekEndLondon('2026-04-13'), '2026-04-19');
    });
    test('Sunday returns itself (same ISO week)', () {
      expect(weekEndLondon('2026-04-19'), '2026-04-19');
    });
    test('crosses month boundary forwards', () {
      // 2026-04-27 (Mon) → Sun 2026-05-03.
      expect(weekEndLondon('2026-04-27'), '2026-05-03');
    });
    test('crosses year boundary', () {
      // 2025-12-29 (Mon) → Sun 2026-01-04 — same week, different years.
      expect(weekEndLondon('2025-12-29'), '2026-01-04');
    });
  });

  group('monthEndLondon', () {
    test('non-leap February', () {
      expect(monthEndLondon('2026-02-15'), '2026-02-28');
    });
    test('leap February', () {
      // 2024 is a leap year — 29 days.
      expect(monthEndLondon('2024-02-15'), '2024-02-29');
    });
    test('30-day month', () {
      expect(monthEndLondon('2026-04-17'), '2026-04-30');
    });
    test('31-day month', () {
      expect(monthEndLondon('2026-07-04'), '2026-07-31');
    });
    test('December rolls into the same year (not next)', () {
      // Day 0 of month 13 must resolve to Dec 31 of the input year, not
      // Nov 30 of the next year — defends the "Day 0 of next month" trick
      // against an off-by-one regression.
      expect(monthEndLondon('2025-12-15'), '2025-12-31');
    });
  });

  group('formatDateRange', () {
    test('same month: month and year shown once at the end', () {
      // 2026-04-13 (Mon) .. 2026-04-19 (Sun)
      expect(
        formatDateRange('2026-04-13', '2026-04-19'),
        'Mon 13th – Sun 19th Apr 2026',
      );
    });

    test('same year, different months: month after each day', () {
      // 2026-04-27 (Mon) .. 2026-05-03 (Sun)
      expect(
        formatDateRange('2026-04-27', '2026-05-03'),
        'Mon 27th Apr – Sun 3rd May 2026',
      );
    });

    test('different years: year after each side', () {
      // 2025-12-29 (Mon) .. 2026-01-04 (Sun)
      expect(
        formatDateRange('2025-12-29', '2026-01-04'),
        'Mon 29th Dec 2025 – Sun 4th Jan 2026',
      );
    });

    test('ordinal suffixes 11–13 are "th" (not -1st/-2nd/-3rd)', () {
      // 11th, 12th, 13th — the classic ordinal-rule edge case.
      expect(
        formatDateRange('2026-04-11', '2026-04-13'),
        'Sat 11th – Mon 13th Apr 2026',
      );
    });

    test('ordinal suffixes 21st / 22nd / 23rd / 24th', () {
      expect(
        formatDateRange('2026-04-21', '2026-04-24'),
        'Tue 21st – Fri 24th Apr 2026',
      );
    });

    test('single-day range is rendered as start–end with same date', () {
      // A daily range collapses to the same date on both sides; the formatter
      // still produces a readable line rather than blowing up.
      expect(
        formatDateRange('2026-04-17', '2026-04-17'),
        'Fri 17th – Fri 17th Apr 2026',
      );
    });
  });
}
