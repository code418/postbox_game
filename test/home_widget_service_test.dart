import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/services/home_widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  group('HomeWidgetService key contract', () {
    // The Kotlin widget provider reads SharedPreferences by literal key name.
    // If the Dart-side constants drift, the Kotlin reader silently returns
    // defaults (0 / false) for every renamed key — the widget would show
    // zeros without any compile-time signal. Pin each literal here; the
    // mirror is in PostboxWidgetProvider.kt:68–73. Any rename requires a
    // matching Kotlin change.
    test('keySignedIn === "signedIn"', () {
      expect(HomeWidgetService.keySignedIn, equals('signedIn'));
    });
    test('keyStreak === "streak"', () {
      expect(HomeWidgetService.keyStreak, equals('streak'));
    });
    test('keyTodayPoints === "todayPoints"', () {
      expect(HomeWidgetService.keyTodayPoints, equals('todayPoints'));
    });
    test('keyWeekPoints === "weekPoints"', () {
      expect(HomeWidgetService.keyWeekPoints, equals('weekPoints'));
    });
    test('keyBoxesFound === "boxesFound"', () {
      expect(HomeWidgetService.keyBoxesFound, equals('boxesFound'));
    });
    test('keyLifetimePoints === "lifetimePoints"', () {
      expect(HomeWidgetService.keyLifetimePoints, equals('lifetimePoints'));
    });
    test('androidProviderName matches the Kotlin class name', () {
      // home_widget's updateWidget(androidName: …) targets the Kotlin
      // AppWidgetProvider class by simple class name. If the Kotlin class
      // is renamed but the Dart constant isn't (or vice versa), redraw
      // requests silently no-op — the widget freezes on its last values.
      // Mirror in PostboxWidgetProvider.kt:20.
      expect(HomeWidgetService.androidProviderName,
          equals('PostboxWidgetProvider'));
    });
    test('appGroupId is a non-empty stable identifier', () {
      // HomeWidget.setAppGroupId scopes the SharedPreferences namespace.
      // Empty/changing values would orphan all prior widget data.
      expect(HomeWidgetService.appGroupId, isNotEmpty);
      expect(HomeWidgetService.appGroupId, equals('PostboxGameWidget'));
    });

    test('every Dart key literal is referenced by PostboxWidgetProvider.kt',
        () {
      // The previous tests pin the Dart constants but couldn't catch a rename
      // on the Kotlin side. Read the provider file and assert every key string
      // appears — a Kotlin-only rename (e.g. KEY_STREAK = "streakCount") would
      // make the provider read SharedPreferences defaults silently, freezing
      // the widget on zeros without any compile-time signal.
      final kt = File(
        'android/app/src/main/kotlin/com/code418/postbox_game/PostboxWidgetProvider.kt',
      ).readAsStringSync();
      for (final key in <String>[
        HomeWidgetService.keySignedIn,
        HomeWidgetService.keyStreak,
        HomeWidgetService.keyTodayPoints,
        HomeWidgetService.keyWeekPoints,
        HomeWidgetService.keyBoxesFound,
        HomeWidgetService.keyLifetimePoints,
      ]) {
        expect(kt, contains('"$key"'),
            reason: 'PostboxWidgetProvider.kt is missing the "$key" key '
                'string — Dart writes it but Kotlin won\'t read it');
      }
    });

    test('androidProviderName matches the Kotlin class declaration', () {
      // The previous test pinned the Dart literal; this one pins the actual
      // Kotlin class definition. A Kotlin class rename without an updateWidget
      // androidName change silently breaks redraws (no-op).
      final kt = File(
        'android/app/src/main/kotlin/com/code418/postbox_game/PostboxWidgetProvider.kt',
      ).readAsStringSync();
      expect(kt, contains('class ${HomeWidgetService.androidProviderName} '));
    });
  });

  group('HomeWidgetService', () {
    const channel = MethodChannel('home_widget');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('signed-out user writes signedIn=false and zero values', () async {
      final service = HomeWidgetService(
        firestore: FakeFirebaseFirestore(),
        auth: MockFirebaseAuth(signedIn: false),
      );

      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keySignedIn], false);
      expect(saved[HomeWidgetService.keyStreak], 0);
      expect(saved[HomeWidgetService.keyTodayPoints], 0);
      expect(saved[HomeWidgetService.keyWeekPoints], 0);
      expect(saved[HomeWidgetService.keyBoxesFound], 0);
      expect(saved[HomeWidgetService.keyLifetimePoints], 0);
      expect(
        calls.any((c) => c.method == 'updateWidget'),
        isTrue,
        reason: 'updateWidget must be called after saving data',
      );
    });

    test('signed-in with today\'s claim writes streak + dailyPoints', () async {
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u1', email: 'u1@example.com'),
      );
      await firestore.collection('users').doc('u1').set({
        'streak': 7,
        'dailyPoints': 21,
        'weeklyPoints': 84,
        'weekStart': weekStartLondon(todayLondon()),
        'uniquePostboxesClaimed': 12,
        'lifetimePoints': 360,
        'lastClaimDate': todayLondon(),
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keySignedIn], true);
      expect(saved[HomeWidgetService.keyStreak], 7);
      expect(saved[HomeWidgetService.keyTodayPoints], 21);
      expect(saved[HomeWidgetService.keyWeekPoints], 84);
      expect(saved[HomeWidgetService.keyBoxesFound], 12);
      expect(saved[HomeWidgetService.keyLifetimePoints], 360);
    });

    test('stale weekStart forces weekPoints to 0', () async {
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u_wk'),
      );
      await firestore.collection('users').doc('u_wk').set({
        'weeklyPoints': 200,
        'weekStart': '1999-01-04',
        'uniquePostboxesClaimed': 40,
        'lifetimePoints': 1200,
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keyWeekPoints], 0);
      // Lifetime totals never reset, so they should still come through.
      expect(saved[HomeWidgetService.keyBoxesFound], 40);
      expect(saved[HomeWidgetService.keyLifetimePoints], 1200);
    });

    test('stale lastClaimDate forces both todayPoints and streak to 0',
        () async {
      // A lastClaimDate older than yesterday means the user's streak has
      // broken; the widget must reflect that immediately rather than showing
      // the stale stored value until the next claim overwrites it.
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u2'),
      );
      await firestore.collection('users').doc('u2').set({
        'streak': 3,
        'dailyPoints': 99,
        'lastClaimDate': '1999-01-01',
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keySignedIn], true);
      expect(saved[HomeWidgetService.keyStreak], 0);
      expect(saved[HomeWidgetService.keyTodayPoints], 0);
    });

    test('yesterday lastClaimDate keeps streak visible, today points 0',
        () async {
      // User claimed yesterday but not today yet — streak is still alive
      // (won't break until a whole day passes with no claim), and today's
      // points should read 0 because no claim today.
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u3'),
      );
      await firestore.collection('users').doc('u3').set({
        'streak': 5,
        'dailyPoints': 42,
        'lastClaimDate': yesterdayLondon(),
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keyStreak], 5);
      expect(saved[HomeWidgetService.keyTodayPoints], 0);
    });

    test('dailyDate=today is trusted over a stale lastClaimDate', () async {
      // Race scenario: the lifetime tx (writes dailyDate + dailyPoints) commits
      // but the parallel streak tx (writes lastClaimDate) hasn't yet — or
      // failed. The widget must trust the dailyDate marker, otherwise it would
      // wrongly show 0 points for a user who just claimed today.
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u_dd_fresh'),
      );
      await firestore.collection('users').doc('u_dd_fresh').set({
        'streak': 4,
        'dailyPoints': 27,
        'dailyDate': todayLondon(),
        'lastClaimDate': yesterdayLondon(), // stale relative to dailyDate
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keyTodayPoints], 27);
      // Streak still alive because lastClaimDate==yesterday is fine.
      expect(saved[HomeWidgetService.keyStreak], 4);
    });

    test('dailyDate=yesterday forces todayPoints to 0 ignoring lastClaimDate',
        () async {
      // dailyDate is the authoritative per-period marker. If it's yesterday,
      // dailyPoints belongs to yesterday — even if lastClaimDate==today (which
      // would only happen via a buggy partial-tx state).
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u_dd_stale'),
      );
      await firestore.collection('users').doc('u_dd_stale').set({
        'streak': 2,
        'dailyPoints': 50,
        'dailyDate': yesterdayLondon(),
        'lastClaimDate': todayLondon(),
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keyTodayPoints], 0);
    });

    test('missing user doc defaults to zeros without throwing', () async {
      final firestore = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'missing'),
      );

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keySignedIn], true);
      expect(saved[HomeWidgetService.keyStreak], 0);
      expect(saved[HomeWidgetService.keyTodayPoints], 0);
    });
  });
}

/// Extracts the last `saveWidgetData` value per key from a sequence of
/// platform channel calls. The `home_widget` package invokes the method with
/// an `id`/`data` argument map.
Map<String, Object?> _savedValues(List<MethodCall> calls) {
  final result = <String, Object?>{};
  for (final call in calls) {
    if (call.method == 'saveWidgetData') {
      final args = (call.arguments as Map).cast<String, Object?>();
      final id = args['id'] as String;
      result[id] = args['data'];
    }
  }
  return result;
}
