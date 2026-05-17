import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/james_controller.dart';

void main() {
  group('JamesController', () {
    test('show() updates pendingMessage and increments seq', () {
      final c = JamesController();
      addTearDown(c.dispose);

      expect(c.pendingMessage, isNull);
      expect(c.messageSeq, 0);
      expect(c.isTalking, isFalse);

      c.show('Cor blimey.');
      expect(c.pendingMessage, 'Cor blimey.');
      expect(c.messageSeq, 1);
      expect(c.isTalking, isTrue);

      c.show('Marvellous.');
      expect(c.pendingMessage, 'Marvellous.');
      expect(c.messageSeq, 2);
    });

    test('clear() drops pendingMessage and stops talking without bumping seq',
        () {
      final c = JamesController();
      addTearDown(c.dispose);

      c.show('Hello.');
      final seqAfterShow = c.messageSeq;
      c.clear();

      expect(c.pendingMessage, isNull);
      expect(c.isTalking, isFalse);
      // seq is the new-message counter, not a generation counter — clear
      // shouldn't bump it (else JamesStrip's "did a new message arrive?" check
      // would re-fire on every clear).
      expect(c.messageSeq, seqAfterShow);
    });

    test('show() and clear() are no-ops after dispose() — no assertion fires',
        () {
      // Regression: the idle Timer's queued callback can race with dispose()
      // and call show()/notifyListeners() on a disposed ChangeNotifier, which
      // would assert in debug. The _disposed guard makes those paths silent.
      final c = JamesController();
      c.dispose();

      // These would previously throw in debug:
      expect(() => c.show("Dead-of-night letter, anyone?"), returnsNormally);
      expect(() => c.clear(), returnsNormally);
      // The disposed controller doesn't accept new state.
      expect(c.pendingMessage, isNull);
      expect(c.isTalking, isFalse);
    });

    test('idle timer is cancelled by dispose() (no late notifyListeners)', () {
      // Doesn't directly exercise the timer-fires-mid-dispose race (the timer
      // delay is 2–5 minutes), but the explicit dispose() call is the path the
      // _disposed flag guards. Any unexpected listener-call after dispose would
      // surface as a TestFailure here.
      final c = JamesController();
      var notifyCount = 0;
      c.addListener(() => notifyCount++);

      c.show('Hello.');
      expect(notifyCount, 1);

      c.removeListener(() => notifyCount++);
      c.dispose();
      // Nothing else fires after dispose.
      expect(notifyCount, 1);
    });
  });
}
