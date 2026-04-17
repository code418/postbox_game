// London-time date helpers for comparing Firestore date strings (YYYY-MM-DD)
// written server-side in Europe/London against a client-computed "today".
//
// The server uses `Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London' })`
// (see `functions/src/_dateUtils.ts`). The helpers below mirror that by
// detecting BST manually since dart:core has no timezone database.

/// Today's date in Europe/London as `YYYY-MM-DD`.
String todayLondon() => formatLondon(DateTime.now().toUtc());

/// Yesterday's date in Europe/London as `YYYY-MM-DD`.
String yesterdayLondon() =>
    formatLondon(DateTime.now().toUtc().subtract(const Duration(days: 1)));

/// Returns YYYY-MM-DD of the Monday of the week containing [today].
/// Mirrors `getWeekStart` in `functions/src/_leaderboardUtils.ts`.
String weekStartLondon(String today) {
  final d = DateTime.utc(
      int.parse(today.substring(0, 4)),
      int.parse(today.substring(5, 7)),
      int.parse(today.substring(8, 10)));
  final day = d.weekday; // 1=Mon..7=Sun
  final diff = day == 7 ? -6 : 1 - day;
  final mon = d.add(Duration(days: diff));
  final y = mon.year.toString().padLeft(4, '0');
  final m = mon.month.toString().padLeft(2, '0');
  final dd = mon.day.toString().padLeft(2, '0');
  return '$y-$m-$dd';
}

/// Returns YYYY-MM-DD of the 1st of the month containing [today].
String monthStartLondon(String today) => '${today.substring(0, 7)}-01';

/// Expected `periodKey` for the leaderboard doc of the given [period]
/// (`daily`/`weekly`/`monthly`/`lifetime`) on [today]. Mirrors `getPeriodKey`
/// in `functions/src/_leaderboardUtils.ts`; used by clients to detect stale
/// leaderboard snapshots if `newDayScoreboard` is delayed or has failed.
String? expectedPeriodKey(String period, String today) {
  switch (period) {
    case 'daily':
      return today;
    case 'weekly':
      return 'week:${weekStartLondon(today)}';
    case 'monthly':
      return 'month:${today.substring(0, 7)}';
    case 'lifetime':
      return 'lifetime';
  }
  return null;
}

/// Formats [utc] as a Europe/London date string `YYYY-MM-DD`.
String formatLondon(DateTime utc) {
  final offset = _isBst(utc) ? const Duration(hours: 1) : Duration.zero;
  final london = utc.add(offset);
  final y = london.year.toString().padLeft(4, '0');
  final m = london.month.toString().padLeft(2, '0');
  final d = london.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Returns true when [utc] falls inside British Summer Time (last Sunday of
/// March 01:00 UTC through last Sunday of October 01:00 UTC).
bool _isBst(DateTime utc) {
  final year = utc.year;
  final bstStart = _lastSundayOfMonthUtcAt01(year, 3);
  final bstEnd = _lastSundayOfMonthUtcAt01(year, 10);
  return !utc.isBefore(bstStart) && utc.isBefore(bstEnd);
}

DateTime _lastSundayOfMonthUtcAt01(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  final offsetToSunday = lastDay.weekday % 7;
  final sunday = lastDay.subtract(Duration(days: offsetToSunday));
  return DateTime.utc(sunday.year, sunday.month, sunday.day, 1);
}
