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

/// Cyphers a player can't reliably tell apart, so the quiz never offers one
/// as a *distractor* alongside another (answer or distractor).
///
/// GR and GVR share their artwork (George V's boxes read "GR"), and GR's
/// label, "George (V or VI)", fits GVIR too: a player standing at a George
/// box could pick a reasonable George and be told it was wrong. When several
/// of these are genuinely nearby, they are all valid answers and all shown.
const List<Set<String>> kQuizLookAlikes = [
  {'GR', 'GVR', 'GVIR'},
];

/// Builds a shuffled quiz option pool of at most [maxOptions] entries.
///
/// Always includes every nearby valid cipher (up to [maxOptions]) so the
/// quiz never asks the user to identify a cypher they can't see. Pads with
/// random distractors drawn from [MonarchInfo.all] when there's room, never
/// two from one [kQuizLookAlikes] group. Tail shuffle randomises the
/// position of the correct answer(s).
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
  final shown = valid.take(maxOptions).toList();
  // A distractor may not share a look-alike group with anything already
  // shown, answer or distractor: two identical George plates side by side
  // would be confusing even when both are wrong.
  bool clashes(String c) => kQuizLookAlikes
      .any((group) => group.contains(c) && group.any(shown.contains));
  final pool = List<String>.from(MonarchInfo.all)..shuffle();
  for (final c in pool) {
    if (shown.length >= maxOptions) break;
    if (shown.contains(c) || clashes(c)) continue;
    shown.add(c);
  }
  return shown..shuffle();
}
