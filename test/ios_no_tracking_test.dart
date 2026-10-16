import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the iOS "no tracking" posture that the App Store privacy label relies
/// on. App Privacy declares "Data Not Used to Track You", so the app shows no
/// App Tracking Transparency prompt; App Review rejected a build under
/// guideline 5.1.2(i) when the label and the app disagreed. These checks keep
/// the binary consistent with the label: Firebase Analytics without Ad ID
/// support, its advertising features off, and no ad or attribution SDKs.
/// See docs/app-store-submission.md §4. Same idea as
/// test/app_store_metadata_test.dart: read the source files directly.
void main() {
  final podfile = File('ios/Podfile').readAsStringSync();
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();

  /// [source] with comments removed, so a commented-out line doesn't count.
  String uncommented(String source, RegExp comment) =>
      source.replaceAll(comment, '');

  test('Podfile links Firebase Analytics without Ad ID support', () {
    final code = uncommented(podfile, RegExp(r'#.*$', multiLine: true));
    final flag = code.indexOf(
        RegExp(r'^\s*\$FirebaseAnalyticsWithoutAdIdSupport\s*=\s*true',
            multiLine: true));
    final install = code.indexOf('flutter_install_all_ios_pods');
    expect(flag, isNot(-1),
        reason: 'without it the firebase_analytics podspec links the full '
            'FirebaseAnalytics pod, which brings in AdSupport/IDFA');
    expect(install, isNot(-1));
    expect(flag, lessThan(install),
        reason: 'the podspec reads the flag when flutter_install_all_ios_pods '
            'evaluates it, so it must be defined first');
  });

  group('Info.plist', () {
    final code = uncommented(plist, RegExp(r'<!--.*?-->', dotAll: true));

    for (final key in [
      'GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED',
      'GOOGLE_ANALYTICS_REGISTRATION_WITH_AD_NETWORK_ENABLED',
      'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE',
      'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA',
      'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS',
    ]) {
      test('turns off $key', () {
        expect(code, matches(RegExp('<key>$key</key>\\s*<false/>')),
            reason: 'Analytics advertising features must stay off while the '
                'privacy label says the app does not track');
      });
    }

    test('has no App Tracking Transparency usage string', () {
      expect(code, isNot(contains('NSUserTrackingUsageDescription')),
          reason: 'asking for tracking permission means the app tracks: the '
              'App Store privacy label (docs/app-store-submission.md §4) '
              'must then change too');
    });
  });

  test('pubspec has no advertising, ATT or attribution packages', () {
    final deps = RegExp(r'^\s+([a-z0-9_]+):', multiLine: true)
        .allMatches(uncommented(pubspec, RegExp(r'#.*$', multiLine: true)))
        .map((m) => m.group(1)!)
        .toSet();
    for (final banned in [
      'google_mobile_ads',
      'app_tracking_transparency',
      'facebook_app_events',
      'appsflyer_sdk',
      'adjust_sdk',
      'flutter_branch_sdk',
      'singular_flutter_sdk',
    ]) {
      expect(deps, isNot(contains(banned)),
          reason: '$banned is an advertising/attribution SDK; adding it '
              'means the app tracks, and the privacy label must change');
    }
  });
}
