import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Persistent advisor strip at the bottom of the screen (Postman James).
/// Shows contextual, light British-humour copy per screen.
class JamesStrip extends StatelessWidget {
  const JamesStrip({
    Key? key,
    required this.message,
    this.icon = Icons.mail,
  }) : super(key: key);

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: postalRed),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Predefined messages for each screen (placeholder copy).
class JamesMessages {
  static const String home = "Ready for a spot of postbox hunting? Tap Nearby or Claim when you\'re out and about.";
  static const String nearby = "Nothing like a good wander. The compass shows roughly where postboxes might be—no exact locations, mind.";
  static const String claim = "Found one? Claim it for the day. Rarer cyphers are worth more points.";
  static const String friends = "Add friends by UID to see them here. More the merrier.";
  static const String leaderboard = "Daily, weekly, monthly—see how you stack up.";
}
