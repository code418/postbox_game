import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/consent_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAnalytics extends Fake implements FirebaseAnalytics {
  bool? collectionEnabled;
  @override
  Future<void> setAnalyticsCollectionEnabled(bool enabled) async {
    collectionEnabled = enabled;
  }
}

void main() {
  late _FakeAnalytics fakeAnalytics;

  setUp(() {
    fakeAnalytics = _FakeAnalytics();
    Analytics.instance = fakeAnalytics;
  });

  Widget gate() => const MaterialApp(
        home: ConsentGate(child: Scaffold(body: Text('HOME'))),
      );

  testWidgets('shows the one-time prompt when the choice is undecided',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(gate());
    await tester.pump();

    expect(find.text('Your data, your choice'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
  });

  testWidgets('Continue persists the choice and reveals the app',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(gate());
    await tester.pump();

    await tester.tap(find.byType(SwitchListTile)); // opt in
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
    expect(await ConsentPreferences.hasDecidedAnalytics(), isTrue);
    expect(await ConsentPreferences.analyticsGranted(), isTrue);
    expect(fakeAnalytics.collectionEnabled, isTrue);
  });

  testWidgets('passes straight through when the choice was already made',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'analytics_consent_decided': true});
    await tester.pumpWidget(gate());
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('Your data, your choice'), findsNothing);
  });
}
