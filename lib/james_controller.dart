import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:postbox_game/james_messages.dart';

class JamesController extends ChangeNotifier {
  JamesController() {
    _scheduleIdleCheck();
  }

  /// Returns the nearest [JamesController], or null if no [JamesControllerScope]
  /// is present in the widget tree (e.g. screens opened via named routes / deep
  /// links that bypass the [Home] shell). Callers use `?.show()` so James
  /// messages are silently skipped rather than crashing.
  static JamesController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JamesControllerScope>()?.notifier;

  String? _pendingMessage;
  String? get pendingMessage => _pendingMessage;

  int _messageSeq = 0;
  int get messageSeq => _messageSeq;

  bool _isTalking = false;
  bool get isTalking => _isTalking;

  /// Set to true in [dispose] so any already-fired idle-timer callback that
  /// races with disposal becomes a no-op rather than calling notifyListeners
  /// on a disposed ChangeNotifier (which asserts in debug).
  bool _disposed = false;

  void show(String message) {
    if (_disposed) return;
    _pendingMessage = message;
    _messageSeq++;
    _isTalking = true;
    notifyListeners();
    _scheduleIdleCheck();
  }

  /// Called internally by JamesStrip after slide-out completes.
  void clear() {
    if (_disposed) return;
    _pendingMessage = null;
    _isTalking = false;
    notifyListeners();
  }

  // ── Idle non-sequitur system ─────────────────────────────────────────────

  static const _idleMin = Duration(minutes: 2);
  static const _idleMax = Duration(minutes: 5);

  Timer? _idleTimer;
  final _random = Random();

  void _scheduleIdleCheck() {
    if (_disposed) return;
    _idleTimer?.cancel();
    final extraSeconds = _random.nextInt((_idleMax - _idleMin).inSeconds);
    _idleTimer = Timer(_idleMin + Duration(seconds: extraSeconds), () {
      if (_disposed) return;
      show(JamesMessages.idle.resolve());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    super.dispose();
  }

}

class JamesControllerScope extends InheritedNotifier<JamesController> {
  const JamesControllerScope({
    super.key,
    required JamesController controller,
    required super.child,
  }) : super(notifier: controller);
}

