import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/theme.dart';

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
    _dismissTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _slideCtrl.reverse().then((_) {
        if (mounted) {
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
              SizedBox(
                width: 44,
                height: 44,
                child: CustomPaint(painter: _JamesMiniPainter()),
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

/// Scaled-down version of the Postman James CustomPainter from intro.dart.
class _JamesMiniPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Body — navy rectangle
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.25, h * 0.48, w * 0.5, h * 0.42),
        Radius.circular(w * 0.08),
      ),
      Paint()..color = royalNavy,
    );

    // Post bag — red rectangle on left hip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.12, h * 0.58, w * 0.16, h * 0.2),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = postalRed,
    );

    // Cap brim — red rectangle
    canvas.drawRect(
      Rect.fromLTWH(w * 0.18, h * 0.17, w * 0.64, h * 0.07),
      Paint()..color = postalRed,
    );

    // Cap top — red rounded top
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.22, h * 0.04, w * 0.56, h * 0.16),
        Radius.circular(w * 0.1),
      ),
      Paint()..color = postalRed,
    );

    // Face — skin-tone circle
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.38),
      w * 0.18,
      Paint()..color = const Color(0xFFFFDDB4),
    );

    // Dot eyes
    canvas.drawCircle(
      Offset(w * 0.43, h * 0.37),
      w * 0.028,
      Paint()..color = const Color(0xFF333333),
    );
    canvas.drawCircle(
      Offset(w * 0.57, h * 0.37),
      w * 0.028,
      Paint()..color = const Color(0xFF333333),
    );

    // Smile
    final smilePath = Path()
      ..moveTo(w * 0.42, h * 0.44)
      ..quadraticBezierTo(w * 0.5, h * 0.49, w * 0.58, h * 0.44);
    canvas.drawPath(
      smilePath,
      Paint()
        ..color = const Color(0xFF8B4513)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.02
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
