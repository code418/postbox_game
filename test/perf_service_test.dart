import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/perf_service.dart';

/// In-process fake of [Trace]; `Fake` throws on any member PerfService doesn't
/// use, catching drift if the wrapper starts reaching for unrelated APIs.
class _FakeTrace extends Fake implements Trace {
  int startCalls = 0;
  int stopCalls = 0;
  final Map<String, String> attributes = {};
  final Map<String, int> metrics = {};

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  void putAttribute(String name, String value) => attributes[name] = value;

  @override
  void setMetric(String name, int value) => metrics[name] = value;
}

class _FakePerformance extends Fake implements FirebasePerformance {
  _FakePerformance({this.throwOnNewTrace = false});

  final bool throwOnNewTrace;
  final List<_FakeTrace> traces = [];
  bool? collectionEnabled;

  _FakeTrace? get lastTrace => traces.isEmpty ? null : traces.last;

  @override
  Trace newTrace(String name) {
    if (throwOnNewTrace) throw StateError('no trace');
    final t = _FakeTrace();
    traces.add(t);
    return t;
  }

  @override
  Future<void> setPerformanceCollectionEnabled(bool enabled) async =>
      collectionEnabled = enabled;
}

void main() {
  tearDown(PerfService.resetForTest);

  test('traceAsync runs the body, returns its value, starts and stops once',
      () async {
    final fake = _FakePerformance();
    PerfService.instance = fake;

    final result = await PerfService.traceAsync<int>(
      'callable.test',
      (trace) async {
        trace.setMetric('count', 5);
        return 42;
      },
      attributes: {'k': 'v'},
    );

    expect(result, 42);
    expect(fake.traces, hasLength(1));
    final t = fake.lastTrace!;
    expect(t.startCalls, 1);
    expect(t.stopCalls, 1);
    expect(t.attributes['k'], 'v');
    expect(t.metrics['count'], 5);
  });

  test('traceAsync stops the trace and rethrows when the body throws',
      () async {
    final fake = _FakePerformance();
    PerfService.instance = fake;

    await expectLater(
      PerfService.traceAsync<int>('t', (_) async => throw StateError('boom')),
      throwsStateError,
    );
    expect(fake.lastTrace!.stopCalls, 1);
  });

  test('a failed newTrace yields a no-op handle but the body still runs',
      () async {
    final fake = _FakePerformance(throwOnNewTrace: true);
    PerfService.instance = fake;

    var ran = false;
    final result = await PerfService.traceAsync<String>('t', (trace) async {
      ran = true;
      // No-ops on the null handle — must not throw.
      trace.putAttribute('k', 'v');
      trace.setMetric('m', 1);
      return 'ok';
    });

    expect(ran, isTrue);
    expect(result, 'ok');
    expect(fake.traces, isEmpty);
  });

  test('start returns a handle that stops only once', () async {
    final fake = _FakePerformance();
    PerfService.instance = fake;

    final handle = await PerfService.start('t');
    await handle.stop();
    await handle.stop(); // idempotent

    expect(fake.lastTrace!.stopCalls, 1);
  });

  test('setCollectionEnabled forwards to the SDK', () async {
    final fake = _FakePerformance();
    PerfService.instance = fake;

    await PerfService.setCollectionEnabled(false);

    expect(fake.collectionEnabled, isFalse);
  });
}
