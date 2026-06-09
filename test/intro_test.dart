import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/remote_config_service.dart';

// Smoke test for the first-run intro flow. Guards the _step state machine and
// the flutter_animate entrance effects added in v1.2.
//
// NOTE: never pumpAndSettle() here — the Mega Points step runs an infinite
// shimmer (flutter_animate .repeat()) and a confetti burst, so settling would
// hang. Pump fixed durations between taps instead. Advancing past a dialogue
// step disposes its AnimatedTextKit (the only Timer source), so teardown stays
// clean as long as the flow ends on the outro step.

/// Stub so JamesMessages.introStep2 can resolve its welcome variant without a
/// live Firebase app. Mirrors the stub in claim_quiz_sheet_test.dart.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
}

void main() {
  setUp(() {
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

    // Steps 0..5 show "Next"; tapping six times lands on the final step (6).
    for (var i = 0; i < 6; i++) {
      expect(find.text('Next'), findsOneWidget,
          reason: 'expected a "Next" button on step $i');
      expect(find.text('Get started'), findsNothing);
      await tester.tap(find.text('Next'));
      // Partially advance the entrance animations without settling.
      await tester.pump(const Duration(milliseconds: 700));
    }

    // Final step: the CTA flips to "Get started" and invokes onDone.
    expect(find.text('Get started'), findsOneWidget);
    expect(doneCalled, isFalse);
    await tester.tap(find.text('Get started'));
    // Advance the clock so any pending flutter_animate `delay:` timers fire
    // before teardown — flutter_animate uses Future.delayed and only .ignore()s
    // (never cancels) it on dispose, so a step left before its delay elapsed
    // leaves a Timer that the test binding flags as "still pending".
    await tester.pump(const Duration(seconds: 2));
    expect(doneCalled, isTrue);
  });
}
