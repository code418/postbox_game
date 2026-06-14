import 'package:cloud_functions/cloud_functions.dart';

/// Region-pinned [FirebaseFunctions] for the app's Cloud Functions.
///
/// All callables are deployed to `europe-west2` (see `functions/src/_region.ts`
/// and ROADMAP v1.3). The default [FirebaseFunctions.instance] targets
/// `us-central1`, so every call site must go through this getter to stay
/// in-region — using the US default would add a cross-Atlantic round-trip.
///
/// [FirebaseFunctions.instanceFor] caches per (app, region), so reading this
/// getter repeatedly is cheap.
FirebaseFunctions get appFunctions =>
    FirebaseFunctions.instanceFor(region: 'europe-west2');
