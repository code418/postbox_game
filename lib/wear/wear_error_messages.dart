import 'package:postbox_game/location_service.dart';

/// Short, watch-appropriate copy for a [LocationServiceException] surfaced on a
/// Wear OS screen.
///
/// The compass scan, the claim-page scan, and the claim attempt each handled
/// this mapping with their own inline `switch` — three copies that had to stay
/// in lockstep by hand. Consolidating them here gives one source of truth for
/// the watch location-error copy (and one place to keep the strings short
/// enough for a round watch face). [action] is the verb for the
/// permission-denied case, e.g. "scan" or "claim".
///
/// Exhaustive over [LocationErrorKind] so a new variant is a compile error
/// rather than a silent fallthrough.
String wearLocationErrorMessage(LocationErrorKind kind, {required String action}) =>
    switch (kind) {
      LocationErrorKind.servicesDisabled => 'Turn on location',
      LocationErrorKind.permissionPermanentlyDenied =>
        'Location denied. Enable in settings.',
      LocationErrorKind.permissionDenied => 'Location needed to $action',
    };
