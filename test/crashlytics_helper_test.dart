import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';

class _RecordedError {
  _RecordedError(this.error, this.reason, this.fatal);
  final Object? error;
  final dynamic reason;
  final bool fatal;
}

/// In-process fake of [FirebaseCrashlytics]; `Fake` throws on any unused member.
class _FakeCrashlytics extends Fake implements FirebaseCrashlytics {
  final Map<String, Object> keys = {};
  final List<_RecordedError> records = [];
  bool? collectionEnabled;

  @override
  Future<void> setCustomKey(String key, Object value) async => keys[key] = value;

  @override
  Future<void> recordError(
    dynamic exception,
    StackTrace? stack, {
    dynamic reason,
    Iterable<Object> information = const [],
    bool? printDetails,
    bool fatal = false,
  }) async =>
      records.add(_RecordedError(exception, reason, fatal));

  @override
  Future<void> recordFlutterError(
    FlutterErrorDetails flutterErrorDetails, {
    bool fatal = false,
  }) async =>
      records.add(_RecordedError(flutterErrorDetails.exception, null, fatal));

  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) async =>
      collectionEnabled = enabled;
}

void main() {
  tearDown(CrashlyticsHelper.resetForTest);

  test('setContext stores the stringified value', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    await CrashlyticsHelper.setContext(CrashlyticsHelper.keyActiveTab, 'claim');

    expect(fake.keys[CrashlyticsHelper.keyActiveTab], 'claim');
  });

  test('setContext truncates over-long values to 1024 chars', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    await CrashlyticsHelper.setContext('k', 'x' * 2000);

    expect((fake.keys['k']! as String).length, 1024);
  });

  test('recordHandled records a non-fatal carrying the reason', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    await CrashlyticsHelper.recordHandled(StateError('x'), StackTrace.current,
        reason: 'startScoring:unavailable');

    expect(fake.records, hasLength(1));
    expect(fake.records.single.fatal, isFalse);
    expect(fake.records.single.reason, 'startScoring:unavailable');
  });

  test('recordHandled dedupes by key within a session', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    await CrashlyticsHelper.recordHandled(StateError('a'), null, dedupeKey: 'd');
    await CrashlyticsHelper.recordHandled(StateError('b'), null, dedupeKey: 'd');

    expect(fake.records, hasLength(1));
  });

  test('recordHandled without a dedupeKey records every call', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    await CrashlyticsHelper.recordHandled(StateError('a'), null);
    await CrashlyticsHelper.recordHandled(StateError('b'), null);

    expect(fake.records, hasLength(2));
  });

  test('reportFlutterError records a generic framework error as FATAL',
      () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    CrashlyticsHelper.reportFlutterError(FlutterErrorDetails(
      exception: StateError('render overflow'),
      library: 'widgets library',
    ));

    expect(fake.records, hasLength(1));
    expect(fake.records.single.fatal, isTrue,
        reason: 'a real framework error must stay a crash');
  });

  test(
      'reportFlutterError downgrades an image-resource failure to a '
      'deduped non-fatal', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    // A failed map tile / network image the moment a user goes offline.
    FlutterErrorDetails tileError() => FlutterErrorDetails(
          exception: Exception('SocketException: Network is unreachable'),
          library: 'image resource service',
        );
    CrashlyticsHelper.reportFlutterError(tileError());
    CrashlyticsHelper.reportFlutterError(tileError());

    // Async recordHandled; let the microtasks drain.
    await Future<void>.delayed(Duration.zero);

    expect(fake.records, hasLength(1),
        reason: 'a blank tile is not a crash, and repeats are deduped');
    expect(fake.records.single.fatal, isFalse);
    expect(fake.records.single.reason, 'image_load');
  });

  test('setCollectionEnabled forwards to the SDK', () async {
    final fake = _FakeCrashlytics();
    CrashlyticsHelper.instance = fake;

    await CrashlyticsHelper.setCollectionEnabled(false);

    expect(fake.collectionEnabled, isFalse);
  });
}
