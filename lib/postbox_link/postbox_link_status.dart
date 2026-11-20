/// Wire models for the `postboxLinkStatus` callable
/// (functions/src/postboxLinks.ts). Forgiving like the app's other models: a
/// missing or odd field degrades to a sensible default instead of throwing.
library;

/// How near the player is to a linked postbox. A band, never a distance or a
/// direction.
enum PostboxProximity {
  claimable('claimable'),
  claimedToday('claimed_today'),
  veryClose('very_close'),
  shortWalk('short_walk'),
  underKm('under_km'),
  far('far'),
  unknown('unknown');

  const PostboxProximity(this.analyticsName);

  /// The `result` value logged with `postbox_link_result`.
  final String analyticsName;

  /// Parses the server's value (the enum's Dart name); anything
  /// unrecognised, including values a newer server might add, is [unknown].
  static PostboxProximity fromWire(Object? value) => PostboxProximity.values
      .firstWhere((p) => p.name == value, orElse: () => unknown);
}

/// The public facts about a linked postbox: the same fields the visitor page
/// shows.
class PostboxPublicInfo {
  const PostboxPublicInfo({
    required this.monarch,
    required this.label,
    required this.phrase,
    required this.points,
    required this.county,
    required this.claimsTotal,
  });

  factory PostboxPublicInfo.fromJson(Object? raw) {
    final json = raw is Map ? raw : const {};
    final claims = json['claims'];
    final total = claims is Map ? claims['total'] : null;
    final points = json['points'];
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    return PostboxPublicInfo(
      monarch: str(json['monarch']),
      label: str(json['label']) ?? 'Plain / no cypher',
      phrase: str(json['phrase']) ?? 'a',
      points: points is num ? points.toInt() : 2,
      county: str(json['county']),
      claimsTotal: total is num ? total.toInt() : 0,
    );
  }

  /// Monarch code (`VR`, `EIIR`, ...) or null for a box with no recorded
  /// cypher.
  final String? monarch;

  /// "Victoria (1837–1901)".
  final String label;

  /// "a Victorian", for "a Victorian postbox"; "a" for a plain box.
  final String phrase;

  final int points;

  /// Display name of the county, or null outside the county data.
  final String? county;

  /// Claims before today.
  final int claimsTotal;

  /// "A Victorian postbox".
  String get headline {
    final p = '$phrase postbox';
    return p[0].toUpperCase() + p.substring(1);
  }

  /// "Never claimed before" / "Claimed once before" / "Claimed 12 times
  /// before".
  String get claimsText => switch (claimsTotal) {
        <= 0 => 'Never claimed before',
        1 => 'Claimed once before',
        _ => 'Claimed $claimsTotal times before',
      };
}

/// The callable's answer.
class PostboxLinkStatus {
  const PostboxLinkStatus({
    required this.found,
    required this.info,
    required this.proximity,
  });

  factory PostboxLinkStatus.fromCallable(Object? raw) {
    final json = raw is Map ? raw : const {};
    return PostboxLinkStatus(
      found: json['found'] == true,
      info: PostboxPublicInfo.fromJson(json['info']),
      proximity: PostboxProximity.fromWire(json['proximity']),
    );
  }

  final bool found;
  final PostboxPublicInfo info;
  final PostboxProximity proximity;
}
