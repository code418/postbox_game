import * as admin from "firebase-admin";

if (!admin.apps.length) {
  // Pin the Storage bucket explicitly. With no argument, admin.storage().bucket()
  // resolves the default bucket name from FIREBASE_CONFIG, which for this project
  // is the legacy `<project>.appspot.com` — but the actual bucket (and where the
  // Flutter client uploads report photos, per firebase_options.dart /
  // google-services.json) is the new-style `the-postbox-game.firebasestorage.app`.
  // The mismatch made submitReport's photo-existence check (reports.ts) and
  // reviewReport's osmChange `.save()` target a bucket that doesn't hold the
  // files, so every report with a photo failed with
  // "one or more photo uploads were not found in storage".
  admin.initializeApp({
    storageBucket: "the-postbox-game.firebasestorage.app",
  });
}
