import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/home_widget_service.dart';

/// Today's date in London (YYYY-MM-DD). Mirrors the private helper inside
/// [HomeWidgetService] so tests can seed Firestore docs with a matching
/// `lastClaimDate` without exposing the helper publicly.
String _todayLondonForTest() {
  final nowUtc = DateTime.now().toUtc();
  // Mirror the BST logic from home_widget_service.dart.
  DateTime lastSundayAt01(int year, int month) {
    final lastDay = DateTime.utc(year, month + 1, 0);
    final sunday = lastDay.subtract(Duration(days: lastDay.weekday % 7));
    return DateTime.utc(sunday.year, sunday.month, sunday.day, 1);
  }
  final bstStart = lastSundayAt01(nowUtc.year, 3);
  final bstEnd = lastSundayAt01(nowUtc.year, 10);
  final inBst = !nowUtc.isBefore(bstStart) && nowUtc.isBefore(bstEnd);
  final london = nowUtc.add(inBst ? const Duration(hours: 1) : Duration.zero);
  return '${london.year.toString().padLeft(4, '0')}-'
      '${london.month.toString().padLeft(2, '0')}-'
      '${london.day.toString().padLeft(2, '0')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
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
        'lastClaimDate': _todayLondonForTest(),
      });

      final service = HomeWidgetService(firestore: firestore, auth: auth);
      await service.refresh();

      final saved = _savedValues(calls);
      expect(saved[HomeWidgetService.keySignedIn], true);
      expect(saved[HomeWidgetService.keyStreak], 7);
      expect(saved[HomeWidgetService.keyTodayPoints], 21);
    });

    test('stale lastClaimDate forces todayPoints=0', () async {
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
      expect(saved[HomeWidgetService.keyStreak], 3);
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
