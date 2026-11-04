/// OAuth client IDs for google_sign_in 7.x initialisation.
///
/// These values are not secrets — they live in the platform config files
/// already shipped with the app (google-services.json on Android, the iOS
/// plist on Apple platforms). They're hoisted here so the phone entry point
/// (main.dart) and the Wear OS entry point (main_wear.dart) can't drift
/// apart silently; the Wear app uses the same Android client and the same
/// Firebase Auth web OAuth client (type 3) for its serverClientId.
library;

/// The Firebase Auth web OAuth client (type 3 in google-services.json).
/// Used directly on web, and as the Android serverClientId so Google
/// Sign-In can issue an ID token usable by signInWithCredential.
const String webClientId =
    '176793005702-7lgiqssuu8i9p5ijn031kbv0tqlptvfg.apps.googleusercontent.com';

/// iOS-type OAuth client. Firebase Auth normally reads this from
/// GoogleService-Info.plist when no clientId is passed, but we pass it
/// explicitly so the value here stays authoritative.
const String iosClientId =
    '176793005702-rmq2h89o58g1lbe6bnqtg9rnllu8gv80.apps.googleusercontent.com';
