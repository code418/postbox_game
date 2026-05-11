import 'package:firebase_auth/firebase_auth.dart';

/// Whether the signed-in user holds the `admin` custom claim that gates the
/// in-app report review interface and the `reviewReport` Cloud Function.
///
/// The claim is granted out-of-band with `functions/set_admin.js`. After it is
/// granted the user must re-authenticate (or call `getIdToken(true)`) before it
/// appears in the token — pass [forceRefresh] to fetch a fresh token.
class AdminAccess {
  AdminAccess._();

  static bool? _cached;

  /// Returns the cached value if known, otherwise resolves and caches it.
  static Future<bool> isAdmin({bool forceRefresh = false}) async {
    if (_cached != null && !forceRefresh) return _cached!;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return _cached = false;
    try {
      final result = await user.getIdTokenResult(forceRefresh);
      final claim = result.claims?['admin'];
      return _cached = claim == true;
    } catch (_) {
      return _cached = false;
    }
  }

  /// Forget the cached value (e.g. on sign-out).
  static void reset() => _cached = null;
}
