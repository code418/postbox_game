import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/postman_james_svg.dart';

class JamesStrip extends StatefulWidget {
  const JamesStrip({super.key, required this.controller});

  final JamesController controller;

  @override
  State<JamesStrip> createState() => _JamesStripState();
}

class _JamesStripState extends State<JamesStrip> with SingleTickerProviderStateMixin {
  late final AnimationController _slideCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final Animation<Offset> _slideAnim = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut));

  String _currentMessage = '';
  int _charIndex = 0;
  Timer? _typeTimer;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
  }

  @override
  void didUpdateWidget(JamesStrip old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onControllerUpdate);
      widget.controller.addListener(_onControllerUpdate);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    _typeTimer?.cancel();
    _dismissTimer?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    final msg = widget.controller.pendingMessage;
    if (msg != null && msg != _currentMessage) {
      _handleNewMessage(msg);
    }
  }

  void _handleNewMessage(String msg) {
    _typeTimer?.cancel();
    _dismissTimer?.cancel();
    setState(() {
      _currentMessage = msg;
      _charIndex = 0;
    });
    if (_slideCtrl.isCompleted) {
      _startTyping(msg);
    } else {
      _slideCtrl.forward().then((_) {
        if (mounted && _currentMessage == msg) _startTyping(msg);
      });
    }
  }

  void _startTyping(String msg) {
    _typeTimer = Timer.periodic(const Duration(milliseconds: 28), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_charIndex >= msg.length) {
        t.cancel();
        _startDismissTimer();
      } else {
        setState(() => _charIndex++);
      }
    });
  }

  void _startDismissTimer() {
    final messageToDismiss = _currentMessage;
    _dismissTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _slideCtrl.reverse().then((_) {
        // Only clear if no new message arrived while sliding out.
        if (mounted && _currentMessage == messageToDismiss) {
          widget.controller.clear();
          setState(() {
            _currentMessage = '';
            _charIndex = 0;
          });
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SlideTransition(
      position: _slideAnim,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 12,
              offset: Offset(0, -4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListenableBuilder(
                listenable: widget.controller,
                builder: (_, __) => PostmanJamesSvg(
                  size: 44,
                  isTalking: widget.controller.isTalking,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _charIndex > 0 ? _currentMessage.substring(0, _charIndex) : '',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

