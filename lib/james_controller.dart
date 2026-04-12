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

  bool _isTalking = false;
  bool get isTalking => _isTalking;

  void show(String message) {
    _pendingMessage = message;
    _isTalking = true;
    notifyListeners();
    _scheduleIdleCheck();
  }

  /// Called internally by JamesStrip after slide-out completes.
  void clear() {
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
    _idleTimer?.cancel();
    final extraSeconds = _random.nextInt((_idleMax - _idleMin).inSeconds);
    _idleTimer = Timer(_idleMin + Duration(seconds: extraSeconds), () {
      show(JamesMessages.idle.resolve());
    });
  }

  @override
  void dispose() {
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

