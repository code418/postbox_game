import * as admin from "firebase-admin";

if (!admin.apps.length) {
  // Pin the Storage bucket explicitly to the project's real GCS bucket. This
  // project predates the `.firebasestorage.app` naming, so its only bucket is
  // `the-postbox-game.appspot.com` (confirmed via `gcloud storage buckets list`
  // and Firebase's SDK config). The `.firebasestorage.app` name FlutterFire
  // wrote into firebase_options.dart does NOT resolve as a GCS bucket, so the
  // Admin SDK (submitReport's photo-existence check, reviewReport's osmChange
  // `.save()`) must use the `.appspot.com` name to match where the client
  // uploads.
  admin.initializeApp({
    storageBucket: "the-postbox-game.appspot.com",
  });
}
