import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

class JamesController extends ChangeNotifier {
  JamesController() {
    _scheduleIdleCheck();
  }

  static JamesController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JamesControllerScope>()!.notifier!;

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
      show(_nonSequiturs[_random.nextInt(_nonSequiturs.length)]);
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  static const List<String> _nonSequiturs = [
    "Did you know the oldest surviving postbox in the UK is in Botchergate, Carlisle? Still standing. Still red.",
    "A Victorian VR postbox weighs about 70 kilograms. Don't try to move one.",
    "The first pillar boxes were painted green. Green! Can you imagine.",
    "There are roughly 115,000 postboxes in the UK. You've got a fair way to go.",
    "Edward VIII was only king for 325 days. His cyphers are rarer for it.",
    "Some postboxes have had the same collection time for over a hundred years. Consistency — that's what I like.",
    "The correct term is 'pillar box'. Though 'postbox' will do. I'm not fussed.",
    "A postbox in Brixham is shaped like a lighthouse. Just thought you should know.",
    "Royal Mail red is officially called 'Pillar Box Red'. The colour is named after the thing. Marvellous.",
    "Apparently squirrels occasionally nest inside postboxes. I've said nothing about this to the sorting office.",
  ];
}

class JamesControllerScope extends InheritedNotifier<JamesController> {
  const JamesControllerScope({
    super.key,
    required JamesController controller,
    required super.child,
  }) : super(notifier: controller);
}

class JamesMessages {
  JamesMessages._();

  static String forIndex(int i) => switch (i) {
        0 =>
          "Nothing like a good wander. The compass shows roughly where postboxes are — no exact locations, mind.",
        1 => "Found one? Get close and claim it. Rarer cyphers are worth more points.",
        2 => "Daily, weekly, monthly — see how you stack up against the competition.",
        3 => "Add friends by UID to see them here. More the merrier.",
        _ => "",
      };
}
