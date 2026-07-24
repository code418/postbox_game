// Process-wide "a claim was recorded" signal.
//
// Screens that load claim-derived data through a one-shot callable (rather
// than a Firestore stream) have no way to learn that the user just claimed
// something. ClaimHistoryScreen is the visible case: its tabs are
// AutomaticKeepAlive inside Home's IndexedStack, so they fetch once at app
// start and keep that answer. Claim a postbox, open History, and it says "No
// claims today — yet. Go find a postbox!" while the leaderboard already shows
// the points.
//
// Anything that settles a claim bumps [revision]; anything showing
// claim-derived data listens and refetches. Deliberately a plain
// ValueNotifier, matching OutboxSync.lastSummary and ClaimOutbox.pendingCount.

import 'package:flutter/foundation.dart';

class ClaimEvents {
  ClaimEvents._();

  /// Incremented once per settled claim (live or flushed from the outbox).
  /// Listeners should treat any change as "refetch", not as a count.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Signal that a claim has committed server-side.
  static void markClaimed() => revision.value++;

  @visibleForTesting
  static void resetForTest() => revision.value = 0;
}
