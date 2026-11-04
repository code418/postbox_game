import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Smoke test for the first-run intro flow. Guards the _step state machine and
// the flutter_animate entrance effects added in v1.2, plus the v1.4 GDPR
// consent step appended as the final first-run step.
//
// NOTE: never pumpAndSettle() here — the Mega Points step runs an infinite
// shimmer (flutter_animate .repeat()) and a confetti burst, so settling would
// hang. Pump fixed durations between taps instead. Advancing past a dialogue
// step disposes its AnimatedTextKit (the only Timer source), so teardown stays
// clean as long as the flow ends on a timer-free step (outro / consent).

/// Stub so JamesMessages.introStep2 can resolve its welcome variant without a
/// live Firebase app. Mirrors the stub in claim_quiz_sheet_test.dart.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
}

/// Records the collection toggle the consent step fires on completion.
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
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAnalytics = _FakeAnalytics();
    Analytics.instance = fakeAnalytics;
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  testWidgets('advances through every step to the onDone callback',
      (tester) async {
    var doneCalled = false;
    await tester.pumpWidget(
      MaterialApp(home: Intro(onDone: () => doneCalled = true)),
    );

    // Steps 0..6 show "Next"; tapping seven times lands on the final
    // (consent) step 7.
    for (var i = 0; i < 7; i++) {
      expect(find.text('Next'), findsOneWidget,
          reason: 'expected a "Next" button on step $i');
      expect(find.text('Get started'), findsNothing);
      await tester.tap(find.text('Next'));
      // Partially advance the entrance animations without settling.
      await tester.pump(const Duration(milliseconds: 700));
    }

    // Final step: the telemetry disclosure with the analytics switch DEFAULT
    // ON (opt-out model), and the CTA flips to "Get started".
    expect(find.text('Get started'), findsOneWidget);
    final switchFinder = find.byType(SwitchListTile);
    expect(switchFinder, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue,
        reason: 'analytics defaults ON (opt-out model)');

    expect(doneCalled, isFalse);
    await tester.tap(find.text('Get started'));
    // Advance the clock so any pending flutter_animate `delay:` timers fire
    // before teardown — flutter_animate uses Future.delayed and only .ignore()s
    // (never cancels) it on dispose, so a step left before its delay elapsed
    // leaves a Timer that the test binding flags as "still pending".
    await tester.pump(const Duration(seconds: 2));
    expect(doneCalled, isTrue);

    // Completing without touching the switch records a decided choice with
    // analytics left on.
    expect(await ConsentPreferences.hasDecidedAnalytics(), isTrue);
    expect(await ConsentPreferences.analyticsGranted(), isTrue);
    expect(fakeAnalytics.collectionEnabled, isTrue);
  });

  testWidgets('opting out on the consent step disables analytics',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Intro(onDone: () {})));
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('Next'));
      await tester.pump(const Duration(milliseconds: 700));
    }
    await tester.tap(find.byType(SwitchListTile)); // switch OFF
    await tester.pump();
    await tester.tap(find.text('Get started'));
    await tester.pump(const Duration(seconds: 2));

    expect(await ConsentPreferences.analyticsGranted(), isFalse);
    expect(fakeAnalytics.collectionEnabled, isFalse);
  });

  testWidgets('Settings replay ends on the outro and never shows consent',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Intro(replay: true)));

    // Replay terminates one step earlier: steps 0..5 show "Next", step 6
    // (outro) shows "Get started" and the consent switch never appears.
    for (var i = 0; i < 6; i++) {
      expect(find.text('Next'), findsOneWidget,
          reason: 'expected a "Next" button on replay step $i');
      await tester.tap(find.text('Next'));
      await tester.pump(const Duration(milliseconds: 700));
    }
    expect(find.text('Get started'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);

    await tester.pump(const Duration(seconds: 2));

    // Replay must not have recorded any consent choice.
    expect(await ConsentPreferences.hasDecidedAnalytics(), isFalse);
  });
}
