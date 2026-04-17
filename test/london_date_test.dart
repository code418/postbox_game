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
}
