import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/legal/privacy_policy_screen.dart';

/// Pins the shape of the Health Connect (workout claims) integration that the
/// Play Console Health apps declaration and Data Safety form rely on: read-only
/// access to exercise sessions + routes, declared ONLY in the phone-side
/// flavours, with Health Connect's required privacy-policy entry points, and a
/// privacy policy that says what the declaration says. Same approach as
/// test/ios_no_tracking_test.dart: read the source files directly.
void main() {
  const phonePath = 'android/app/src/phone/AndroidManifest.xml';
  const autoPath = 'android/app/src/auto/AndroidManifest.xml';
  final phone = File(phonePath).readAsStringSync();
  final auto = File(autoPath).readAsStringSync();

  String uncommented(String xml) => xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  /// The text between `<!-- health-connect:begin (name)` and
  /// `<!-- health-connect:end (name) -->`, whitespace-normalised.
  String block(String xml, String name) {
    final m = RegExp('health-connect:begin \\($name\\).*?-->(.*?)<!-- health-connect:end \\($name\\) -->',
            dotAll: true)
        .firstMatch(xml);
    expect(m, isNotNull, reason: 'missing health-connect $name block');
    return m!.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  group('phone and auto manifests', () {
    for (final entry in {phonePath: phone, autoPath: auto}.entries) {
      final code = uncommented(entry.value);
      test('${entry.key} declares read-only exercise + route access', () {
        expect(code, contains('android.permission.health.READ_EXERCISE"'));
        expect(code, contains('android.permission.health.READ_EXERCISE_ROUTES"'));
        expect(code, contains('<package android:name="com.google.android.apps.healthdata"/>'));
      });
      test('${entry.key} has both Health Connect privacy-policy entry points', () {
        expect(code, contains('androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE'),
            reason: 'Android 13 and lower: the rationale activity');
        expect(code, contains('android.intent.action.VIEW_PERMISSION_USAGE'));
        expect(code, contains('android.intent.category.HEALTH_PERMISSIONS'));
        expect(code, contains('android.permission.START_VIEW_PERMISSION_USAGE'),
            reason: 'Android 14+: the alias must be guarded by this permission');
        expect(code, contains('com.code418.postbox_game.health.HealthPrivacyActivity'));
      });
    }

    test('the two flavours carry identical Health Connect blocks', () {
      expect(block(phone, 'permissions'), block(auto, 'permissions'));
      expect(block(phone, 'privacy'), block(auto, 'privacy'));
    });
  });

  test('main and wear manifests declare no health permissions or activities', () {
    for (final path in [
      'android/app/src/main/AndroidManifest.xml',
      'android/app/src/wear/AndroidManifest.xml',
    ]) {
      final code = uncommented(File(path).readAsStringSync());
      expect(code, isNot(contains('android.permission.health.')), reason: path);
      expect(code, isNot(contains('HealthPrivacyActivity')), reason: path);
    }
  });

  test('no manifest asks to write, read in the background, or read history', () {
    final manifests = Directory('android/app/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('AndroidManifest.xml'));
    for (final f in manifests) {
      final code = uncommented(f.readAsStringSync());
      expect(code, isNot(contains('android.permission.health.WRITE_')), reason: f.path);
      expect(code, isNot(contains('READ_HEALTH_DATA_IN_BACKGROUND')), reason: f.path);
      expect(code, isNot(contains('READ_HEALTH_DATA_HISTORY')), reason: f.path);
    }
  });

  test('connect-client is linked into the phone-side flavours only', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final lines = gradle
        .split('\n')
        .where((l) => l.contains('androidx.health.connect:connect-client') && !l.trim().startsWith('//'))
        .map((l) => l.trim().split(RegExp(r'\s+')).first)
        .toSet();
    expect(lines, {'phoneImplementation', 'autoImplementation'});
  });

  test('MainActivity stays a plain FlutterActivity and registers the bridge', () {
    final src = File('android/app/src/main/kotlin/com/code418/postbox_game/MainActivity.kt').readAsStringSync();
    expect(src, contains('class MainActivity: FlutterActivity()'));
    final code = src.replaceAll(RegExp(r'//.*$', multiLine: true), '');
    expect(code, isNot(contains('FlutterFragmentActivity')));
    expect(src, contains('HealthConnectRegistrar.register(flutterEngine)'));
  });

  test('the wear flavour compiles a no-op registrar', () {
    final stub = File('android/app/src/wear/kotlin/com/code418/postbox_game/health/HealthConnectRegistrar.kt')
        .readAsStringSync();
    expect(stub, contains('object HealthConnectRegistrar'));
    expect(stub, isNot(contains('HealthConnectPlugin')));
  });

  test("Health Connect's privacy link opens the hosted privacy policy", () {
    final src = File(
            'android/app/src/healthconnect/kotlin/com/code418/postbox_game/health/HealthPrivacyActivity.kt')
        .readAsStringSync();
    final url = RegExp(r'PRIVACY_URL = "([^"]+)"').firstMatch(src)?.group(1);
    expect(url, isNotNull);
    expect(url, startsWith(kHostedPrivacyPolicyUrl),
        reason: 'Health Connect must show the same policy as the Play listing');
    expect(url, endsWith('#health-connect'));
    expect(File('web/privacy-policy.html').readAsStringSync(), contains('id="health-connect"'));
  });

  group('privacy policy and data safety page describe the integration', () {
    const limitedUse = 'The App\'s use of information received from Health Connect adheres to the Health '
        'Connect Permissions policy, including the Limited Use requirements.';
    for (final path in ['assets/legal/privacy_policy.md', 'web/privacy-policy.html']) {
      test('$path has the Health Connect section and Limited Use statement', () {
        final text = File(path).readAsStringSync().replaceAll('&#39;', "'").replaceAll('&rsquo;', "'");
        expect(text, contains('Health Connect'));
        expect(text.replaceAll(RegExp(r'\s+'), ' '), contains(limitedUse));
      });
    }
    test('web/data-safety.html lists fitness info', () {
      expect(File('web/data-safety.html').readAsStringSync(), contains('Fitness info'));
    });
  });

  test('no cross-platform health plugin and no HealthKit on iOS (yet)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^\s+health:', multiLine: true).hasMatch(pubspec), isFalse,
        reason: 'the integration is a thin Kotlin bridge; the `health` plugin links HealthKit into iOS');
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('NSHealthShareUsageDescription')));
  });
}
