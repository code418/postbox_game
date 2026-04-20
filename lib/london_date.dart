// London-time date helpers for comparing Firestore date strings (YYYY-MM-DD)
// written server-side in Europe/London against a client-computed "today".
//
// The server uses `Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London' })`
// (see `functions/src/_dateUtils.ts`). The helpers below mirror that by
// detecting BST manually since dart:core has no timezone database.

/// Today's date in Europe/London as `YYYY-MM-DD`.
String todayLondon() => formatLondon(DateTime.now().toUtc());

/// Yesterday's date in Europe/London as `YYYY-MM-DD`.
///
/// Derived by subtracting one calendar day from [todayLondon], not by
/// subtracting 24h from UTC before formatting. The latter is wrong during
/// the first hour after spring-forward: London wall-clock 00:30 on
/// 2026-03-30 is UTC 23:30 on 2026-03-29 (BST), and 24h earlier is UTC
/// 23:30 on 2026-03-28 — GMT — which formats as `2026-03-28`, skipping
/// the actual yesterday (2026-03-29).
String yesterdayLondon() {
  final today = todayLondon();
  final d = DateTime.utc(
    int.parse(today.substring(0, 4)),
    int.parse(today.substring(5, 7)),
    int.parse(today.substring(8, 10)),
  ).subtract(const Duration(days: 1));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

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

/// Returns YYYY-MM-DD of the Sunday that ends the week of [today].
String weekEndLondon(String today) {
  final start = weekStartLondon(today);
  final d = DateTime.utc(
    int.parse(start.substring(0, 4)),
    int.parse(start.substring(5, 7)),
    int.parse(start.substring(8, 10)),
  ).add(const Duration(days: 6));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Returns YYYY-MM-DD of the last day of the month containing [today].
String monthEndLondon(String today) {
  final y = int.parse(today.substring(0, 4));
  final m = int.parse(today.substring(5, 7));
  // Day 0 of month+1 in dart:core == last day of month m.
  final d = DateTime.utc(y, m + 1, 0);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Formats a `YYYY-MM-DD` range as `"Mon 1st – Sun 7th Apr 2026"` /
/// `"Fri 28th Mar – Thu 3rd Apr 2026"` / `"Mon 29th Dec 2025 – Sun 4th Jan 2026"`
/// depending on whether month/year are shared.
String formatDateRange(String startYmd, String endYmd) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final sDate = DateTime.utc(
    int.parse(startYmd.substring(0, 4)),
    int.parse(startYmd.substring(5, 7)),
    int.parse(startYmd.substring(8, 10)),
  );
  final eDate = DateTime.utc(
    int.parse(endYmd.substring(0, 4)),
    int.parse(endYmd.substring(5, 7)),
    int.parse(endYmd.substring(8, 10)),
  );
  final sDay = days[sDate.weekday - 1];
  final eDay = days[eDate.weekday - 1];
  final sd = '${sDate.day}${_ordinal(sDate.day)}';
  final ed = '${eDate.day}${_ordinal(eDate.day)}';
  if (sDate.year == eDate.year && sDate.month == eDate.month) {
    return '$sDay $sd – $eDay $ed ${months[eDate.month - 1]} ${eDate.year}';
  }
  if (sDate.year == eDate.year) {
    return '$sDay $sd ${months[sDate.month - 1]} – $eDay $ed ${months[eDate.month - 1]} ${eDate.year}';
  }
  return '$sDay $sd ${months[sDate.month - 1]} ${sDate.year} – $eDay $ed ${months[eDate.month - 1]} ${eDate.year}';
}

String _ordinal(int day) {
  if (day >= 11 && day <= 13) return 'th';
  switch (day % 10) {
    case 1: return 'st';
    case 2: return 'nd';
    case 3: return 'rd';
    default: return 'th';
  }
}

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
