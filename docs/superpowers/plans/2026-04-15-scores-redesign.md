# Scores Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5-tab leaderboard with a 4-tab + friends-toggle design, add a tappable `UserProfilePage`, and store per-period points on user documents so the friends view works for all periods.

**Architecture:** Three backend changes (new pure helper + two function updates) land first; three Flutter changes (new page, updated leaderboard, tappable friends list) land second. Tests use the existing pure-unit mock pattern for TypeScript and `FakeFirebaseFirestore` / smoke tests for Flutter.

**Tech Stack:** TypeScript (Firebase Functions v2), Dart/Flutter, Firestore, `firebase-functions-test`, `fake_cloud_firestore`, `flutter_test`.

---

## File map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `functions/src/_leaderboardUtils.ts` | Add `getPeriodResetFields` pure helper |
| Modify | `functions/src/startScoring.ts` | Increment `dailyPoints`/`weeklyPoints`/`monthlyPoints` on user doc during claim |
| Modify | `functions/src/newDayScoreboard.ts` | Batch-reset period fields on all user docs at midnight |
| Create | `lib/user_profile_page.dart` | `UserProfilePage` widget — loads user doc + 4 leaderboard docs, shows stats + ranks |
| Modify | `lib/leaderboard_screen.dart` | 4 tabs + toggle; `_FriendsPeriodList` replaces `_FriendsLeaderboardList`; names tappable |
| Modify | `lib/friends_screen.dart` | Friend rows tappable → push `UserProfilePage` |
| Modify | `functions/src/test/test.index.ts` | Tests for `getPeriodResetFields` |
| Modify | `test/widget_test.dart` | Smoke test for `UserProfilePage` |

---

## Task 1 — Add `getPeriodResetFields` helper (TDD, TypeScript)

**Files:**
- Modify: `functions/src/_leaderboardUtils.ts`
- Modify: `functions/src/test/test.index.ts`

- [ ] **Step 1: Write the failing tests**

Open `functions/src/test/test.index.ts`. After the last `describe` block, add:

```typescript
describe("getPeriodResetFields", () => {
  it("always resets dailyPoints", () => {
    const fields = getPeriodResetFields("2026-04-15", "2026-04-13", "2026-04-01");
    assert.strictEqual(fields.dailyPoints, 0);
  });

  it("does not reset weeklyPoints on a non-Monday", () => {
    const fields = getPeriodResetFields("2026-04-15", "2026-04-13", "2026-04-01");
    assert.strictEqual(fields.weeklyPoints, undefined);
  });

  it("resets weeklyPoints when today equals weekStart (Monday)", () => {
    const fields = getPeriodResetFields("2026-04-14", "2026-04-14", "2026-04-01");
    assert.strictEqual(fields.weeklyPoints, 0);
  });

  it("does not reset monthlyPoints mid-month", () => {
    const fields = getPeriodResetFields("2026-04-15", "2026-04-13", "2026-04-01");
    assert.strictEqual(fields.monthlyPoints, undefined);
  });

  it("resets monthlyPoints when today equals monthStart (1st)", () => {
    const fields = getPeriodResetFields("2026-05-01", "2026-05-01", "2026-05-01");
    assert.strictEqual(fields.monthlyPoints, 0);
  });

  it("resets both weeklyPoints and monthlyPoints on Monday the 1st", () => {
    // 2026-06-01 is a Monday
    const fields = getPeriodResetFields("2026-06-01", "2026-06-01", "2026-06-01");
    assert.strictEqual(fields.weeklyPoints, 0);
    assert.strictEqual(fields.monthlyPoints, 0);
  });
});
```

Add `getPeriodResetFields` to the import at the top of the file:
```typescript
import { getWeekStart, getMonthStart, getPeriodKey, mergePeriodEntries, mergeLifetimeEntries, updateUserLeaderboards, getPeriodResetFields } from "../_leaderboardUtils";
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd functions && npm test 2>&1 | tail -20
```

Expected: 6 new failures mentioning `getPeriodResetFields is not a function`.

- [ ] **Step 3: Implement `getPeriodResetFields` in `_leaderboardUtils.ts`**

Open `functions/src/_leaderboardUtils.ts`. Add this export **before** the existing exports (anywhere near the top of the file is fine):

```typescript
/**
 * Returns the user-doc fields that must be zeroed out on the given day.
 * dailyPoints is always reset; weeklyPoints only on Monday (today === weekStart);
 * monthlyPoints only on the 1st (today === monthStart).
 */
export function getPeriodResetFields(
  today: string,
  weekStart: string,
  monthStart: string
): Record<string, number> {
  const fields: Record<string, number> = { dailyPoints: 0 };
  if (today === weekStart) fields.weeklyPoints = 0;
  if (today === monthStart) fields.monthlyPoints = 0;
  return fields;
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd functions && npm test 2>&1 | tail -20
```

Expected: all existing tests still pass, 6 new tests pass. Total should now be 120.

- [ ] **Step 5: Commit**

```bash
git add functions/src/_leaderboardUtils.ts functions/src/test/test.index.ts
git commit -m "feat(backend): add getPeriodResetFields helper"
```

---

## Task 2 — Increment period points in `startScoring.ts`

**Files:**
- Modify: `functions/src/startScoring.ts`

- [ ] **Step 1: Locate the lifetime transaction `tx.set` call**

In `functions/src/startScoring.ts`, find the `tx.set` call inside `database.runTransaction` around line 216:

```typescript
tx.set(userRef, { uniquePostboxesClaimed: newUnique, lifetimePoints: newLifetimePoints }, { merge: true });
```

- [ ] **Step 2: Replace it to also increment period point fields**

```typescript
tx.set(
  userRef,
  {
    uniquePostboxesClaimed: newUnique,
    lifetimePoints: newLifetimePoints,
    dailyPoints: admin.firestore.FieldValue.increment(lifetimePointsIncrement),
    weeklyPoints: admin.firestore.FieldValue.increment(lifetimePointsIncrement),
    monthlyPoints: admin.firestore.FieldValue.increment(lifetimePointsIncrement),
  },
  { merge: true }
);
```

Note: `lifetimePointsIncrement` is already computed on the line above (`const lifetimePointsIncrement = earnedPoints.reduce((s, p) => s + p, 0);`) so no new variables are needed.

- [ ] **Step 3: Run existing tests to confirm no regression**

```bash
cd functions && npm test 2>&1 | tail -20
```

Expected: same count as after Task 1 — all tests still pass.

- [ ] **Step 4: Commit**

```bash
git add functions/src/startScoring.ts
git commit -m "feat(backend): increment dailyPoints/weeklyPoints/monthlyPoints on claim"
```

---

## Task 3 — Reset period points in `newDayScoreboard.ts`

**Files:**
- Modify: `functions/src/newDayScoreboard.ts`

- [ ] **Step 1: Add `getPeriodResetFields` to the import**

Find the existing import from `_leaderboardUtils` at the top of `functions/src/newDayScoreboard.ts`:

```typescript
import {
  getWeekStart,
  getMonthStart,
  getPeriodKey,
  LeaderboardEntry,
} from "./_leaderboardUtils";
```

Replace it with:

```typescript
import {
  getWeekStart,
  getMonthStart,
  getPeriodKey,
  getPeriodResetFields,
  LeaderboardEntry,
} from "./_leaderboardUtils";
```

- [ ] **Step 2: Add the batch-reset logic after the leaderboard rebuilds**

Find the block starting at around line 105:

```typescript
const [weeklyResult, monthlyResult] = await Promise.allSettled([
  rebuildPeriodLeaderboard("weekly", weekStart, yesterday),
  rebuildPeriodLeaderboard("monthly", monthStart, yesterday),
]);
```

After the two `if (weeklyResult…)` / `if (monthlyResult…)` logger calls, add:

```typescript
// 3. Reset per-user period point fields.
// dailyPoints resets every day; weeklyPoints on Mondays; monthlyPoints on the 1st.
try {
  const resetFields = getPeriodResetFields(today, weekStart, monthStart);
  const usersSnap = await db.collection("users").get();
  const BATCH_LIMIT = 499;
  const batches: admin.firestore.WriteBatch[] = [];
  let batch: admin.firestore.WriteBatch = db.batch();
  let batchCount = 0;
  for (const doc of usersSnap.docs) {
    batch.update(doc.ref, resetFields);
    batchCount++;
    if (batchCount === BATCH_LIMIT) {
      batches.push(batch);
      batch = db.batch();
      batchCount = 0;
    }
  }
  if (batchCount > 0) batches.push(batch);
  await Promise.all(batches.map((b) => b.commit()));
  logger.info(
    `Period fields reset: [${Object.keys(resetFields).join(", ")}] across ${usersSnap.docs.length} users`
  );
} catch (resetErr) {
  logger.error("Period point reset failed (non-fatal):", resetErr);
}
```

No new imports are needed — `admin` is already imported at the top of the file (`import * as admin from "firebase-admin"`), so `admin.firestore.WriteBatch` is available.

- [ ] **Step 3: Run existing tests to confirm no regression**

```bash
cd functions && npm test 2>&1 | tail -20
```

Expected: all tests still pass.

- [ ] **Step 4: Commit**

```bash
git add functions/src/newDayScoreboard.ts
git commit -m "feat(backend): reset dailyPoints/weeklyPoints/monthlyPoints at midnight rollover"
```

---

## Task 4 — Create `UserProfilePage` widget (TDD, Flutter)

**Files:**
- Create: `lib/user_profile_page.dart`
- Modify: `test/widget_test.dart`

- [ ] **Step 1: Write the failing smoke test**

In `test/widget_test.dart`, add a new group after the existing groups:

```dart
group('UserProfilePage', () {
  testWidgets('renders display name and stat tiles without crashing',
      (tester) async {
    // UserProfilePage uses FirebaseFirestore.instance and FirebaseAuth.instance
    // which are mocked by setupFirebaseMocks(). The FutureBuilder will remain
    // in loading state — this test just verifies the widget tree builds cleanly.
    await tester.pumpWidget(
      const MaterialApp(
        home: UserProfilePage(uid: 'test-uid-123'),
      ),
    );
    await tester.pump();
    // AppBar should render with one of the two title strings.
    expect(
      find.textContaining('Profile'),
      findsOneWidget,
    );
  });
});
```

Add the import at the top of `test/widget_test.dart` (alongside the existing imports):
```dart
import 'package:postbox_game/user_profile_page.dart';
```

- [ ] **Step 2: Run the test to confirm it fails (file not found)**

```bash
cd /home/richard/gits/postbox_game && flutter test test/widget_test.dart 2>&1 | tail -20
```

Expected: compilation error — `user_profile_page.dart` does not exist.

- [ ] **Step 3: Create `lib/user_profile_page.dart`**

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/theme.dart';

class UserProfilePage extends StatelessWidget {
  final String uid;

  const UserProfilePage({super.key, required this.uid});

  static Route<void> route(String uid) =>
      MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid));

  Future<_ProfileData> _load() async {
    final db = FirebaseFirestore.instance;
    final results = await Future.wait([
      db.collection('users').doc(uid).get(),
      db.collection('leaderboards').doc('daily').get(),
      db.collection('leaderboards').doc('weekly').get(),
      db.collection('leaderboards').doc('monthly').get(),
      db.collection('leaderboards').doc('lifetime').get(),
    ]);

    final userSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
    final userData = userSnap.data() ?? {};

    final periods = ['daily', 'weekly', 'monthly', 'lifetime'];
    final Map<String, int?> ranks = {};
    for (var i = 0; i < periods.length; i++) {
      final lbSnap = results[i + 1] as DocumentSnapshot<Map<String, dynamic>>;
      final entries = lbSnap.data()?['entries'] as List<dynamic>? ?? [];
      int? rank;
      for (var j = 0; j < entries.length; j++) {
        final e = entries[j];
        if (e is Map && e['uid'] == uid) {
          rank = j + 1;
          break;
        }
      }
      ranks[periods[i]] = rank;
    }

    return _ProfileData(
      displayName: userData['displayName'] as String? ?? 'Unknown',
      createdAt: (userData['createdAt'] as Timestamp?)?.toDate(),
      streak: (userData['streak'] as num?)?.toInt() ?? 0,
      uniqueBoxes: (userData['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
      lifetimePoints: (userData['lifetimePoints'] as num?)?.toInt() ?? 0,
      ranks: ranks,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final isOwn = currentUid == uid;

    return Scaffold(
      appBar: AppBar(title: Text(isOwn ? 'Your Profile' : 'Player Profile')),
      body: FutureBuilder<_ProfileData>(
        future: _load(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: postalRed));
          }
          if (snap.hasError || snap.data == null) {
            return Padding(
              padding: const EdgeInsets.only(bottom: kJamesStripClearance),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: AppSpacing.md),
                    Text('Could not load profile',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            );
          }
          return _ProfileBody(data: snap.data!);
        },
      ),
    );
  }
}

class _ProfileData {
  final String displayName;
  final DateTime? createdAt;
  final int streak;
  final int uniqueBoxes;
  final int lifetimePoints;
  final Map<String, int?> ranks;

  const _ProfileData({
    required this.displayName,
    required this.createdAt,
    required this.streak,
    required this.uniqueBoxes,
    required this.lifetimePoints,
    required this.ranks,
  });
}

class _ProfileBody extends StatelessWidget {
  final _ProfileData data;

  const _ProfileBody({required this.data});

  String _joinedText() {
    if (data.createdAt == null) return '';
    return 'Joined ${DateFormat('MMMM yyyy').format(data.createdAt!)}';
  }

  String _initials() {
    final name = data.displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: postalRed,
              child: Text(
                _initials(),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.displayName,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                  if (data.createdAt != null)
                    Text(
                      _joinedText(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Headline stats ───────────────────────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.md, horizontal: AppSpacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StatCell(
                    value: '${data.uniqueBoxes}',
                    label: 'Unique boxes',
                    color: postalGold),
                const VerticalDivider(),
                _StatCell(
                    value: '${data.lifetimePoints}',
                    label: 'Lifetime pts',
                    color: postalRed),
                const VerticalDivider(),
                _StatCell(
                    value: '🔥 ${data.streak}',
                    label: 'Day streak',
                    color: Colors.green),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // ── Rankings ─────────────────────────────────────────────────────────
        Text(
          'CURRENT RANKINGS',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Card(
          child: Column(
            children: [
              for (final period in ['daily', 'weekly', 'monthly', 'lifetime'])
                _RankRow(
                  period: period,
                  rank: data.ranks[period],
                  isLast: period == 'lifetime',
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Rankings shown for top 100 players per period',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.6),
              ),
        ),
        const SizedBox(height: kJamesStripClearance),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatCell(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  final String period;
  final int? rank;
  final bool isLast;

  const _RankRow(
      {required this.period, required this.rank, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final label = period[0].toUpperCase() + period.substring(1);
    final isFirst = rank == 1;
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          trailing: rank != null
              ? Text(
                  '#$rank${isFirst ? ' 🏆' : ''}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isFirst ? postalGold : null,
                      ),
                )
              : Text(
                  'Unranked',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.5),
                      ),
                ),
        ),
        if (!isLast) const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}
```

- [ ] **Step 4: Check that `intl` is in pubspec.yaml**

```bash
grep 'intl:' /home/richard/gits/postbox_game/pubspec.yaml
```

If not present, add it under `dependencies:`:
```yaml
  intl: ^0.19.0
```
Then run `flutter pub get`.

- [ ] **Step 5: Run the smoke test**

```bash
cd /home/richard/gits/postbox_game && flutter test test/widget_test.dart -n "UserProfilePage" 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Run full test suite**

```bash
flutter test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/user_profile_page.dart test/widget_test.dart pubspec.yaml pubspec.lock
git commit -m "feat(flutter): add UserProfilePage with stats and rank breakdown"
```

---

## Task 5 — Refactor `LeaderboardScreen` (4 tabs + toggle + tappable names)

**Files:**
- Modify: `lib/leaderboard_screen.dart`

This task rewrites `leaderboard_screen.dart` in-place. Read it first, then make all changes as described.

- [ ] **Step 1: Update `_periods` and add `_friendsOnly` state**

In `_LeaderboardScreenState`, change:
```dart
static const List<String> _periods = ['daily', 'weekly', 'monthly', 'lifetime', 'friends'];
```
to:
```dart
static const List<String> _periods = ['daily', 'weekly', 'monthly', 'lifetime'];
bool _friendsOnly = true;
```

Change the `TabController` length from `_periods.length` (which was 5) — it still uses `_periods.length` so no change needed there (now 4).

- [ ] **Step 2: Update `_onTabChanged` — remove the friends branch**

Replace:
```dart
void _onTabChanged() {
  if (_tabController.indexIsChanging) return;
  final idx = _tabController.index;
  if (idx == _periods.indexOf('lifetime')) {
    JamesController.of(context)
        ?.show(JamesMessages.navLifetimeScores.resolve());
  } else if (idx == _periods.indexOf('friends')) {
    JamesController.of(context)
        ?.show(JamesMessages.navFriendsLeaderboard.resolve());
  }
}
```

with:

```dart
void _onTabChanged() {
  if (_tabController.indexIsChanging) return;
  if (_tabController.index == _periods.indexOf('lifetime')) {
    JamesController.of(context)
        ?.show(JamesMessages.navLifetimeScores.resolve());
  }
}
```

- [ ] **Step 3: Update `build` to add the toggle row**

Replace the entire `build` method body in `_LeaderboardScreenState`:

```dart
@override
Widget build(BuildContext context) {
  return Column(
    children: [
      Container(
        color: Theme.of(context).colorScheme.surface,
        child: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: _periods
              .map((p) => Tab(text: p[0].toUpperCase() + p.substring(1)))
              .toList(),
        ),
      ),
      // Friends-only toggle row
      Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Friends only',
                style: Theme.of(context).textTheme.bodyMedium),
            Switch(
              value: _friendsOnly,
              activeColor: postalRed,
              onChanged: (v) => setState(() => _friendsOnly = v),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: TabBarView(
          controller: _tabController,
          children: _periods.map((period) {
            if (_friendsOnly) {
              return _FriendsPeriodList(
                key: ValueKey('friends_$period'),
                period: period,
              );
            }
            return _LeaderboardList(
              key: ValueKey('global_$period'),
              period: period,
            );
          }).toList(),
        ),
      ),
    ],
  );
}
```

- [ ] **Step 4: Add `onTap` to `_LeaderboardList` entries**

In `_LeaderboardListState.build`, inside the `itemBuilder` where the `Card` is returned (around line 247), change the `ListTile` to add an `onTap`:

```dart
return Card(
  color: isCurrentUser
      ? postalRed.withValues(alpha: 0.08)
      : null,
  child: ListTile(
    onTap: entryUid != null
        ? () => Navigator.of(context).push(UserProfilePage.route(entryUid))
        : null,
    leading: _rankWidget(rank),
    title: Text(
      displayName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: isCurrentUser
          ? const TextStyle(fontWeight: FontWeight.bold)
          : null,
    ),
    trailing: Text(
      trailingText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: isCurrentUser
                ? postalRed
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: isCurrentUser
                ? FontWeight.bold
                : FontWeight.normal,
          ),
    ),
  ),
);
```

Add the import at the top of `leaderboard_screen.dart`:
```dart
import 'package:postbox_game/user_profile_page.dart';
```

- [ ] **Step 5: Rename `_FriendsLeaderboardList` → `_FriendsPeriodList` and add `period` parameter**

Replace the class declaration:
```dart
class _FriendsLeaderboardList extends StatefulWidget {
  const _FriendsLeaderboardList();
```
with:
```dart
class _FriendsPeriodList extends StatefulWidget {
  final String period;
  const _FriendsPeriodList({required this.period});
```

Replace the state class declaration:
```dart
class _FriendsLeaderboardListState extends State<_FriendsLeaderboardList> {
```
with:
```dart
class _FriendsPeriodListState extends State<_FriendsPeriodList> {
```

Update the `createState` method:
```dart
@override
State<_FriendsPeriodList> createState() => _FriendsPeriodListState();
```

- [ ] **Step 6: Make `_fetchScores` period-aware**

In `_FriendsPeriodListState`, replace the `_fetchScores` method with a period-aware version. The method currently builds entries with `uniquePostboxesClaimed` + `totalPoints`. Replace it entirely:

```dart
Future<List<Map<String, dynamic>>> _fetchScores(Set<String> friendUids) async {
  final visibleUids = <String>{
    if (_currentUid != null) _currentUid!,
    ...friendUids,
  }.toList();

  const batchSize = 30;
  final allDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  for (var i = 0; i < visibleUids.length; i += batchSize) {
    final batch = visibleUids.sublist(
        i, (i + batchSize).clamp(0, visibleUids.length));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: batch)
          .get();
      allDocs.addAll(snap.docs);
    } catch (_) {}
  }

  final isLifetime = widget.period == 'lifetime';
  final scoreField = switch (widget.period) {
    'daily' => 'dailyPoints',
    'weekly' => 'weeklyPoints',
    'monthly' => 'monthlyPoints',
    _ => 'uniquePostboxesClaimed', // lifetime
  };

  final entries = allDocs
      .where((d) => d.exists)
      .map((d) => <String, dynamic>{
            'uid': d.id,
            'displayName': d.data()['displayName'] as String? ?? 'Unknown',
            'score': (d.data()[scoreField] as num?)?.toInt() ?? 0,
            // Keep both lifetime fields for the trailing text formatter
            'uniquePostboxesClaimed':
                (d.data()['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
            'totalPoints':
                (d.data()['lifetimePoints'] as num?)?.toInt() ?? 0,
          })
      .toList();

  if (isLifetime) {
    entries.sort((a, b) {
      final ua = a['uniquePostboxesClaimed'] as int;
      final ub = b['uniquePostboxesClaimed'] as int;
      if (ub != ua) return ub - ua;
      return (b['totalPoints'] as int) - (a['totalPoints'] as int);
    });
  } else {
    entries.sort((a, b) => (b['score'] as int) - (a['score'] as int));
  }
  return entries;
}
```

- [ ] **Step 7: Update the score change detection to be period-aware**

In `_FriendsPeriodListState`, replace the three tracking fields:
```dart
int _lastUniqueBoxes = -1;
int _lastLifetimePoints = -1;
```
with:
```dart
int _lastPeriodScore = -1;
int _lastSecondaryScore = -1;
```

In the `build` method, find the block that reads `myUniqueBoxes` and `myLifetimePoints` and replace it:

```dart
// Determine score fields to watch based on active period.
final scoreField = switch (widget.period) {
  'daily' => 'dailyPoints',
  'weekly' => 'weeklyPoints',
  'monthly' => 'monthlyPoints',
  _ => 'uniquePostboxesClaimed',
};
final myPeriodScore = (userData?[scoreField] as num?)?.toInt() ?? 0;
final mySecondaryScore =
    (userData?['lifetimePoints'] as num?)?.toInt() ?? 0;
final friendsChanged = !setEquals(_lastFriendUids, friendUids);
final scoresChanged = myPeriodScore != _lastPeriodScore ||
    mySecondaryScore != _lastSecondaryScore;
if (friendsChanged || scoresChanged) {
  _lastFriendUids = friendUids;
  _lastPeriodScore = myPeriodScore;
  _lastSecondaryScore = mySecondaryScore;
  _scoreFuture = _fetchScores(friendUids);
}
```

- [ ] **Step 8: Update the trailing text and add `onTap` in the item builder**

In the `ListView.builder` inside `_FriendsPeriodListState`, replace the trailing text logic and add `onTap`. The `itemBuilder` currently computes `uniqueBoxes`, `totalPoints`, `pctText`, `trailingText`. Replace those lines and the `Card`:

```dart
itemBuilder: (context, index) {
  final e = entries[index];
  final rank = index + 1;
  final displayName = e['displayName'] as String? ?? 'Unknown';
  final entryUid = e['uid'] as String?;
  final isCurrentUser = entryUid != null && entryUid == _currentUid;
  final isLifetime = widget.period == 'lifetime';

  final String trailingText;
  if (isLifetime) {
    final uniqueBoxes = e['uniquePostboxesClaimed'] as int;
    final totalPoints = e['totalPoints'] as int;
    final pctText = (_totalPostboxes != null && _totalPostboxes! > 0)
        ? ' (${(uniqueBoxes / _totalPostboxes! * 100).toStringAsFixed(3)}%)'
        : '';
    trailingText =
        '$uniqueBoxes ${uniqueBoxes == 1 ? 'box' : 'boxes'}$pctText · $totalPoints pts';
  } else {
    final score = e['score'] as int;
    trailingText = '$score pts';
  }

  return Card(
    color: isCurrentUser ? postalRed.withValues(alpha: 0.08) : null,
    child: ListTile(
      onTap: entryUid != null
          ? () => Navigator.of(context)
              .push(UserProfilePage.route(entryUid))
          : null,
      leading: _friendsRankWidget(rank),
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrentUser
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      trailing: Text(
        trailingText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: isCurrentUser
                  ? postalRed
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight:
                  isCurrentUser ? FontWeight.bold : FontWeight.normal,
            ),
      ),
    ),
  );
},
```

Also update the pull-to-refresh `onRefresh` callback — it currently calls `_fetchScores(_lastFriendUids)`:
```dart
onRefresh: () {
  setState(() {
    _scoreFuture = _fetchScores(_lastFriendUids);
  });
  return _scoreFuture!;
},
```
This is already correct — no change needed.

- [ ] **Step 9: Update the empty-friends message to reference the Friends tab (not "Friends tab" wording)**

Find the message inside the `friendUids.isEmpty` block:
```dart
'Add friends from the Friends tab to see how you compare.',
```
This is still accurate — no change needed.

- [ ] **Step 10: Run the full test suite**

```bash
cd /home/richard/gits/postbox_game && flutter test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 11: Run flutter analyze**

```bash
flutter analyze 2>&1 | tail -20
```

Expected: no issues.

- [ ] **Step 12: Commit**

```bash
git add lib/leaderboard_screen.dart
git commit -m "feat(flutter): 4-tab leaderboard with friends toggle and tappable names"
```

---

## Task 6 — Tappable names in `FriendsScreen`

**Files:**
- Modify: `lib/friends_screen.dart`

- [ ] **Step 1: Add import for `UserProfilePage`**

At the top of `lib/friends_screen.dart`, add:
```dart
import 'package:postbox_game/user_profile_page.dart';
```

- [ ] **Step 2: Add `onTap` to each friend `ListTile`**

In the `ListView.builder` inside the `StreamBuilder`, find the `Card` containing the `ListTile` for each friend (around line 325). The current `ListTile` has no `onTap`. Add it:

```dart
return Card(
  child: ListTile(
    onTap: isLoading
        ? null
        : () => Navigator.of(context)
            .push(UserProfilePage.route(friendUid)),
    leading: CircleAvatar(
      // ... rest unchanged
```

The `onTap` is disabled while the display name is still loading, so the profile page always has a resolved UID.

- [ ] **Step 3: Run the full test suite**

```bash
cd /home/richard/gits/postbox_game && flutter test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Run flutter analyze**

```bash
flutter analyze 2>&1 | tail -10
```

Expected: no issues.

- [ ] **Step 5: Commit**

```bash
git add lib/friends_screen.dart
git commit -m "feat(flutter): friend rows tappable → UserProfilePage"
```

---

## Verification checklist

After all tasks are complete, verify end-to-end:

- [ ] Open Scores tab — toggle defaults to ON, list shows friends' scores for the active period
- [ ] Switch toggle off — list shows global top-100; your row pinned at bottom if outside top 100
- [ ] Switch between Daily / Weekly / Monthly / Lifetime — data updates in both toggle states
- [ ] Tap any display name in leaderboard → `UserProfilePage` opens; no UID visible; "Unranked" shown gracefully for periods where user is outside top 100
- [ ] Tap your own name → AppBar title is "Your Profile"
- [ ] Tap a friend's name in the Friends screen → same `UserProfilePage`
- [ ] Backend: after midnight, `dailyPoints` on user docs is 0; after a claim, `dailyPoints`, `weeklyPoints`, `monthlyPoints` all increment by the claim's points
- [ ] `flutter analyze` reports no issues
- [ ] `flutter test` all passing
- [ ] `cd functions && npm test` all passing
