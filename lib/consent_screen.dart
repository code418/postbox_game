import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/legal/privacy_policy_screen.dart';
import 'package:postbox_game/theme.dart';

/// The reusable consent disclosure body, shared by the intro's final step and
/// [ConsentGate] so the copy stays single-source. Styled for the dark navy
/// gradient both hosts render on. The host owns the opt-in switch state.
class ConsentContent extends StatelessWidget {
  const ConsentContent({
    super.key,
    required this.analyticsOptIn,
    required this.onAnalyticsChanged,
  });

  final bool analyticsOptIn;
  final ValueChanged<bool> onAnalyticsChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your data, your choice',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: AppSpacing.md),
        const Text(
          'To keep the app working we collect crash reports and performance '
          'traces. You can turn those off any time in Settings → Privacy.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        const SizedBox(height: AppSpacing.md),
        const Text(
          'We also collect anonymous usage analytics. You can switch that off '
          'here, or later in Settings → Privacy:',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        const SizedBox(height: AppSpacing.sm),
        SwitchListTile(
          value: analyticsOptIn,
          onChanged: onAnalyticsChanged,
          title: const Text(
            'Share anonymous usage analytics',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            'Helps us understand which features matter',
            style: TextStyle(color: Colors.white60),
          ),
          contentPadding: EdgeInsets.zero,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: postalGold),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const PrivacyPolicyScreen()),
            ),
            child: const Text('Privacy policy'),
          ),
        ),
      ],
    );
  }
}

/// One-time consent prompt for EXISTING users (installs that predate the
/// consent step in the intro). New users decide inside the intro, so the
/// choice is already recorded and this gate passes straight through.
class ConsentGate extends StatefulWidget {
  const ConsentGate({super.key, required this.child});

  final Widget child;

  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  bool? _decided;
  bool _optIn = true; // analytics defaults ON (opt-out model)

  @override
  void initState() {
    super.initState();
    ConsentPreferences.hasDecidedAnalytics().then((d) {
      if (mounted) setState(() => _decided = d);
    });
  }

  Future<void> _continue() async {
    await ConsentPreferences.setAnalyticsConsent(_optIn);
    unawaited(Analytics.setCollectionEnabled(_optIn));
    if (mounted) setState(() => _decided = true);
  }

  @override
  Widget build(BuildContext context) {
    final decided = _decided;
    if (decided == true) return widget.child;

    // Loading (a few ms) and the prompt share the intro's navy backdrop so
    // there's no flash of Home before the takeover.
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [royalNavy, Color(0xFF3D0C13)],
          ),
        ),
        child: SafeArea(
          child: decided == null
              ? const SizedBox.expand()
              : Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                            vertical: AppSpacing.lg),
                        child: ConsentContent(
                          analyticsOptIn: _optIn,
                          onAnalyticsChanged: (v) =>
                              setState(() => _optIn = v),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _continue,
                          child: const Text('Continue'),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
