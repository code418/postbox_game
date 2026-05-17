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
