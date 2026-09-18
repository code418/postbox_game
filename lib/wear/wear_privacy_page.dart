import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/services/telemetry_consent.dart';
import 'package:postbox_game/wear/wear_round_inset.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Telemetry opt-outs for the watch.
///
/// Consent is device-local SharedPreferences state (see [ConsentPreferences]),
/// so a choice made on the phone does NOT reach the watch and vice versa. The
/// watch therefore needs its own control: the privacy policy promises every
/// telemetry stream can be switched off, and until this page existed the watch
/// collected without offering the objection.
///
/// Only two streams are listed. Performance Monitoring is forced off on Wear
/// (`applyStoredTelemetryPreferences(includePerf: false)`) precisely so a third
/// row isn't needed — there is no vertical budget for one inside the round
/// display's inscribed square.
///
/// Reachable while signed OUT as well as in: guest scanning is a first-class
/// mode on the watch, and a signed-out user must still be able to withdraw.
class WearPrivacyPage extends StatefulWidget {
  const WearPrivacyPage({super.key});

  @override
  State<WearPrivacyPage> createState() => _WearPrivacyPageState();
}

class _WearPrivacyPageState extends State<WearPrivacyPage> {
  bool? _analytics;
  bool? _crashReports;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final analytics = await ConsentPreferences.analyticsGranted();
    final crash = await ConsentPreferences.crashReportingEnabled();
    if (!mounted) return;
    setState(() {
      _analytics = analytics;
      _crashReports = crash;
    });
  }

  /// Re-applies the stored consent to the live SDKs so the toggle takes effect
  /// immediately rather than at the next cold start. Mirrors the phone's
  /// Settings → Privacy handlers.
  Future<void> _apply() => applyStoredTelemetryPreferences(includePerf: false);

  Future<void> _setAnalytics(bool value) async {
    setState(() => _analytics = value);
    await ConsentPreferences.setAnalyticsConsent(value);
    await _apply();
  }

  Future<void> _setCrashReports(bool value) async {
    setState(() => _crashReports = value);
    await ConsentPreferences.setCrashReportingEnabled(value);
    await _apply();
  }

  @override
  Widget build(BuildContext context) {
    return WearPrivacyView(
      analytics: _analytics,
      crashReports: _crashReports,
      onAnalyticsChanged: (v) => unawaited(_setAnalytics(v)),
      onCrashReportsChanged: (v) => unawaited(_setCrashReports(v)),
    );
  }
}

/// Pure, prop-driven rendering for [WearPrivacyPage].
///
/// Split out for the same reason as `WearClaimView`: every state has to be
/// constructible directly by `test/wear_round_fit_test.dart`, which renders it
/// at 192 dp and fails if anything strays outside the inscribed circle.
///
/// Null toggle values mean "still reading SharedPreferences".
class WearPrivacyView extends StatelessWidget {
  const WearPrivacyView({
    super.key,
    required this.analytics,
    required this.crashReports,
    required this.onAnalyticsChanged,
    required this.onCrashReportsChanged,
  });

  final bool? analytics;
  final bool? crashReports;
  final ValueChanged<bool> onAnalyticsChanged;
  final ValueChanged<bool> onCrashReportsChanged;

  bool get _loaded => analytics != null && crashReports != null;

  @override
  Widget build(BuildContext context) {
    // Material, not a bare Container: [Switch] requires a Material ancestor,
    // and the round-fit test renders this view standalone (no Scaffold).
    return Material(
      color: Colors.black,
      child: WearRoundInset(
        child: Center(
          child: _loaded
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Privacy',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: WearSpacing.sm),
                    _toggleRow(
                      context,
                      label: 'Analytics',
                      value: analytics!,
                      onChanged: onAnalyticsChanged,
                    ),
                    const SizedBox(height: WearSpacing.xs),
                    _toggleRow(
                      context,
                      label: 'Crash reports',
                      value: crashReports!,
                      onChanged: onCrashReportsChanged,
                    ),
                  ],
                )
              : const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _toggleRow(
    BuildContext context, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Scaled down so two full-size Material switches fit the ~136 dp
        // inscribed square alongside their labels. Transform.scale is visual
        // only, so the 48 dp tap target is preserved.
        Transform.scale(
          scale: 0.8,
          child: Switch(value: value, onChanged: onChanged),
        ),
      ],
    );
  }
}
