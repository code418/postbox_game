import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/admin/admin_reports_screen.dart';

void main() {
  Widget host(AdminPhotoThumb thumb) =>
      MaterialApp(home: Scaffold(body: Center(child: thumb)));

  const photo = <String, dynamic>{'storagePath': 'report_photos/u1/a.jpg'};

  testWidgets(
      'tapping a thumb whose URL lookup failed retries instead of throwing',
      (tester) async {
    // Crashlytics 6c390e36: a transient Storage `retry-limit-exceeded` was
    // cached in the thumb's URL future, and the unawaited tap handler
    // rethrew it on every tap, which the zone reported as a FATAL crash.
    var calls = 0;
    Future<String> resolver(String path) {
      calls++;
      if (calls == 1) {
        return Future<String>.error(Exception('retry-limit-exceeded'));
      }
      // Never completes: we only need to see that a fresh lookup started.
      return Completer<String>().future;
    }

    await tester.pumpWidget(host(AdminPhotoThumb(
      photo: photo,
      downloadUrlFor: resolver,
    )));
    await tester.pump();
    expect(calls, 1);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);

    await tester.tap(find.byType(AdminPhotoThumb));
    await tester.pump();

    // No uncaught error (the test would fail on one), the admin is told, and
    // the failed lookup was dropped so the thumb fetches again.
    expect(tester.takeException(), isNull);
    expect(find.textContaining("Couldn't load that photo"), findsOneWidget);
    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('a full-size photo that fails to download shows an error state',
      (tester) async {
    await tester.pumpWidget(host(AdminPhotoThumb(
      photo: photo,
      // flutter_test's HttpClient answers every request with a 400, so the
      // dialog's Image.network always fails here.
      downloadUrlFor: (_) async => 'https://example.invalid/a.jpg',
    )));
    await tester.pump();

    await tester.tap(find.byType(AdminPhotoThumb));
    await tester.pump();
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text("Couldn't load the photo."), findsOneWidget);
  });
}
