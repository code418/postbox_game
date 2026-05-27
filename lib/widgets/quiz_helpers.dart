import 'package:postbox_game/monarch_info.dart';

/// Helpers shared by the phone's [ClaimQuizSheet] and the simplified watch
/// claim flow ([WearClaimPage]). Both paths needed identical
/// "collect-the-currently-claimable-cyphers" and "build a shuffled option
/// pool" logic; before this extraction the watch held a near-copy that
/// drifted in `Map` typing and the option count.
///
/// Kept as plain top-level functions (rather than a class) so they're trivial
/// to unit-test without instantiating a widget state.

/// Walks the server's per-user `postboxes` map and returns the set of distinct
/// monarch keys whose boxes are still unclaimed today AND known to
/// [MonarchInfo.all]. Postboxes carrying an unknown cypher are skipped: the
/// option pool wouldn't be able to render them anyway, and they take the
/// direct-claim path elsewhere (no quiz triggered).
///
/// [postboxesValues] should be the `.values` iterable of the slim postbox map
/// returned by the `nearbyPostboxes` callable (`Map<String, dynamic>` keyed
/// by postbox id → `Map` of `monarch`, `claimedToday`, …). Accepts the
/// permissive `Map<dynamic, dynamic>` typing so both call sites — which store
/// their slim maps with subtly different inner casts — can pass straight in.
Set<String> collectValidQuizCiphers(Iterable<dynamic> postboxesValues) {
  final ciphers = <String>{};
  for (final p in postboxesValues) {
    if (p is! Map) continue;
    if (p['claimedToday'] == true) continue;
    final monarch = p['monarch'];
    if (monarch is String &&
        monarch.isNotEmpty &&
        MonarchInfo.all.contains(monarch)) {
      ciphers.add(monarch);
    }
  }
  return ciphers;
}

/// Builds a shuffled quiz option pool of at most [maxOptions] entries.
///
/// Always includes every nearby valid cipher (up to [maxOptions]) so the
/// quiz never asks the user to identify a cypher they can't see. Pads with
/// random distractors drawn from [MonarchInfo.all] when there's room. Tail
/// shuffle randomises the position of the correct answer(s).
///
/// When [validCiphers] is larger than [maxOptions], only [maxOptions] of them
/// appear as choices, but the caller's "is this a valid answer?" check should
/// still accept any cipher from [validCiphers] — this helper only controls
/// what's *rendered*.
List<String> buildQuizOptions(
  Set<String> validCiphers, {
  required int maxOptions,
}) {
  final valid = validCiphers.toList()..shuffle();
  final pickedValid = valid.take(maxOptions).toList();
  final pool = List<String>.from(MonarchInfo.all)
    ..removeWhere(pickedValid.contains)
    ..shuffle();
  final fillers = pool.take(maxOptions - pickedValid.length).toList();
  return ([...pickedValid, ...fillers]..shuffle());
}
