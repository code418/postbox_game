// Google sign-in failure classification.
//
// Crashlytics (2026-05..07) showed 86 non-fatal
// `GoogleSignInExceptionCode.unknownError` events from 5 users across 13
// sessions — ~17 per user per session. The description was always
// "No credential available: No credentials available", i.e. Android's
// Credential Manager had no Google account to offer, and the UI answered with
// the generic "Sign in failed. Please try again." So the users retried, and
// retried, and could never succeed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/user_repository.dart';

GoogleSignInException _noAccount() => const GoogleSignInException(
      code: GoogleSignInExceptionCode.unknownError,
      description: 'No credential available: No credentials available',
    );

/// Resolve a package's lib/ directory from the generated package config, so
/// this doesn't hard-code a pub-cache path or a version number.
Directory? _packageLib(String name) {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final packages = (jsonDecode(config.readAsStringSync())
      as Map<String, dynamic>)['packages'] as List<dynamic>;
  for (final p in packages.cast<Map<String, dynamic>>()) {
    if (p['name'] == name) {
      var root = Uri.parse(p['rootUri'] as String);
      if (!root.hasScheme) root = File(config.path).parent.uri.resolveUri(root);
      // rootUri has no trailing slash, so resolve() would drop its last
      // segment; re-add one before resolving packageUri against it.
      if (!root.path.endsWith('/')) {
        root = root.replace(path: '${root.path}/');
      }
      return Directory.fromUri(root.resolve(p['packageUri'] as String));
    }
  }
  return null;
}

void main() {
  group('isNoGoogleAccountOnDevice', () {
    test('recognises the no-account failure', () {
      expect(isNoGoogleAccountOnDevice(_noAccount()), isTrue);
    });

    test('does not swallow other unknownError failures', () {
      expect(
        isNoGoogleAccountOnDevice(const GoogleSignInException(
          code: GoogleSignInExceptionCode.unknownError,
          description: 'Something else went wrong',
        )),
        isFalse,
      );
      expect(
        isNoGoogleAccountOnDevice(
            const GoogleSignInException(code: GoogleSignInExceptionCode.unknownError)),
        isFalse,
      );
    });

    test('does not fire for a different code with the same wording', () {
      expect(
        isNoGoogleAccountOnDevice(const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
          description: 'No credential available: ...',
        )),
        isFalse,
      );
    });
  });

  group('googleSignInFailureMessage', () {
    test('tells the user to add an account rather than to retry', () {
      final message = googleSignInFailureMessage(_noAccount());
      expect(message, isNotNull);
      expect(message, contains('No Google account'));
      expect(message!.toLowerCase(), isNot(contains('try again')),
          reason: 'retrying is exactly what cannot work here');
    });

    test('configuration failures point at the email fallback', () {
      expect(
        googleSignInFailureMessage(const GoogleSignInException(
            code: GoogleSignInExceptionCode.providerConfigurationError)),
        contains('email'),
      );
    });

    test('returns null when there is no specific advice', () {
      expect(
        googleSignInFailureMessage(
            const GoogleSignInException(code: GoogleSignInExceptionCode.canceled)),
        isNull,
        reason: 'the caller falls back to its own generic wording',
      );
    });
  });

  test('the plugin still uses the description prefix we match on', () {
    // isNoGoogleAccountOnDevice string-matches a description built inside
    // google_sign_in_android, because the plugin collapses
    // GetCredentialFailureType.noCredential into the catch-all unknownError
    // and exposes no distinct code. Re-read the resolved plugin source so a
    // version bump that rewords it fails HERE, loudly, instead of silently
    // dropping users back to the unhelpful generic message.
    final lib = _packageLib('google_sign_in_android');
    if (lib == null || !lib.existsSync()) {
      markTestSkipped('google_sign_in_android not resolved; skipping');
      return;
    }
    final source = File('${lib.path}/google_sign_in_android.dart');
    if (!source.existsSync()) {
      markTestSkipped('plugin entrypoint moved; skipping');
      return;
    }
    expect(
      source.readAsStringSync(),
      contains("'$kNoGoogleCredentialPrefix"),
      reason: 'google_sign_in_android no longer builds its noCredential '
          'description with the "$kNoGoogleCredentialPrefix" prefix. Check '
          'whether it now exposes a distinct GoogleSignInExceptionCode and '
          'switch isNoGoogleAccountOnDevice onto it.',
    );
  });
}
