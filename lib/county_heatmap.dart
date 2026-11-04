import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_profile_page.dart';

/// Named palette of colours users may pick to represent themselves on the
/// heatmap. Keys are the stable strings persisted in `users/{uid}.mapColor`;
/// adding a new colour is safe, but renaming a key will orphan existing
/// preferences (they fall back to the auto-palette).
const Map<String, Color> kMapColourPalette = {
  'postal_red': postalRed,
  'indigo': Colors.indigo,
  'teal': Colors.teal,
  'deep_orange': Colors.deepOrange,
  'purple': Colors.purple,
  'green': Color(0xFF388E3C),
  'brown': Colors.brown,
  'cyan': Color(0xFF0097A7),
  'pink': Color(0xFFEC407A),
  'amber': Color(0xFFFF8F00),
  'blue_grey': Colors.blueGrey,
};

/// Auto-palette used when a user has no `mapColor` preference. Order is
/// preserved from the original deterministic mapping so that existing friends
/// keep the colour they had before chosen colours were introduced.
const List<Color> _autoPalette = <Color>[
  Colors.indigo,
  Colors.teal,
  Colors.deepOrange,
  Colors.purple,
  Color(0xFF388E3C),
  Colors.brown,
  Color(0xFF0097A7),
  Color(0xFFEC407A),
  Color(0xFFFF8F00),
  Colors.blueGrey,
];

/// Resolves the heatmap colour for [uid]. If [chosenKey] names a palette
/// entry, that colour wins; otherwise the deterministic uid-hash fallback is
/// used. [isSelf] only affects the fallback (self gets postal red) so that an
/// explicitly chosen colour always overrides the default.
Color mapColourFor({
  required String uid,
  required bool isSelf,
  String? chosenKey,
}) {
  if (chosenKey != null) {
    final picked = kMapColourPalette[chosenKey];
    if (picked != null) return picked;
  }
  if (isSelf) return postalRed;
  final h = uid.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
  return _autoPalette[h % _autoPalette.length];
}

/// UK county heatmap showing which of (the user + their friends) leads each
/// county's lifetime ranking. Colours each polygon by the leading uid using
/// the user's chosen `mapColor` if set, falling back to a deterministic
/// uid-hash palette (with self defaulting to postal red).
///
/// The map intentionally has no tile layer — the heatmap is the content, a
/// base map would distract and incur OSM tile traffic for no benefit.
/// Picks the leading leaderboard entry for a county. Friends-only: the top
/// entry whose uid is in [candidates] (entries are server-sorted, so the first
/// match is the highest-ranked friend). Global: the top entry regardless.
/// Returns null when no eligible entry exists.
@visibleForTesting
Map<String, dynamic>? pickCountyLeaderEntry(
    List<dynamic> entries, Set<String> candidates, bool friendsOnly) {
  for (final e in entries) {
    if (e is! Map) continue;
    final entryUid = e['uid'] as String?;
    if (entryUid == null) continue;
    if (friendsOnly && !candidates.contains(entryUid)) continue;
    return Map<String, dynamic>.from(e);
  }
  return null;
}

/// Maximum number of named player chips in the legend before it collapses the
/// rest into a "+N more" chip.
const int _kMaxLegendChips = 8;

/// Orders legend entries: self first, then by counties led (desc), then by
/// display name, then uid. The last two keys keep the row stable across
/// rebuilds — a comparator returning 0 for a pair leaves the order at the mercy
/// of iteration order, which changes between rebuilds.
///
/// [leaderUidByCounty] is one uid per led county, so repeats are the count.
@visibleForTesting
List<String> orderLegendLeaders(
  Iterable<String> leaderUidByCounty, {
  required String myUid,
  required Map<String, String> displayNames,
}) {
  final counties = <String, int>{};
  for (final uid in leaderUidByCounty) {
    counties[uid] = (counties[uid] ?? 0) + 1;
  }
  return counties.keys.toList()
    ..sort((a, b) {
      if (a == b) return 0;
      if (a == myUid) return -1;
      if (b == myUid) return 1;
      final byCount = counties[b]!.compareTo(counties[a]!);
      if (byCount != 0) return byCount;
      final byName = (displayNames[a] ?? '')
          .toLowerCase()
          .compareTo((displayNames[b] ?? '').toLowerCase());
      return byName != 0 ? byName : a.compareTo(b);
    });
}

class CountyHeatmap extends StatefulWidget {
  const CountyHeatmap({super.key, this.friendsOnly = true});

  /// When true (default), each county is coloured by the leader among {me + my
  /// friends}; when false, by the global leader. Mirrors the "Friends only"
  /// toggle on the other leaderboard tabs.
  final bool friendsOnly;

  @override
  State<CountyHeatmap> createState() => _CountyHeatmapState();
}

class _CountyHeatmapState extends State<CountyHeatmap> {
  late Future<_HeatmapData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(CountyHeatmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The toggle flips friendsOnly; reload so the county leaders recompute.
    if (oldWidget.friendsOnly != widget.friendsOnly) {
      // Braces, not an arrow: `=> _future = _load()` makes the closure return
      // the Future, which trips setState's "callback returned a Future" assert
      // and red-screens the tab in debug on every toggle flip.
      setState(() {
        _future = _load();
      });
    }
  }

  Future<_HeatmapData> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw StateError('Not signed in');
    }
    final db = FirebaseFirestore.instance;

    // Load asset and friends list in parallel.
    final results = await Future.wait<dynamic>([
      rootBundle.loadString('assets/uk_counties_simplified.geojson'),
      db.collection('users').doc(uid).get(),
    ]);
    final geojsonText = results[0] as String;
    final myDoc = results[1] as DocumentSnapshot<Map<String, dynamic>>;
    final friends =
        ((myDoc.data()?['friends'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(growable: false);

    // Resolve display names for everyone in the candidate set so the bottom
    // sheet can show "Alex" rather than a UID. Batch via whereIn (max 30 per
    // query) — a 200-friend list pays 7 round-trips instead of 201.
    final candidates = <String>{uid, ...friends};
    final candidateList = candidates.toList(growable: false);
    const batchSize = 30;
    final batches = <List<String>>[
      for (var i = 0; i < candidateList.length; i += batchSize)
        candidateList.sublist(
            i, (i + batchSize).clamp(0, candidateList.length)),
    ];
    final batchSnaps = await Future.wait(batches.map(
      (b) => db.collection('users').where(FieldPath.documentId, whereIn: b).get(),
    ));
    final names = <String, String>{};
    final chosenColours = <String, String>{};
    for (final snap in batchSnaps) {
      for (final d in snap.docs) {
        final data = d.data();
        final n = data['displayName'] as String?;
        names[d.id] = (n == null || n.isEmpty) ? _synthName(d.id) : n;
        final mc = data['mapColor'];
        if (mc is String && kMapColourPalette.containsKey(mc)) {
          chosenColours[d.id] = mc;
        }
      }
    }
    // Fall back to a synthesised name for any candidate whose user doc was
    // missing from the batch result (e.g. a deleted account still in someone's
    // friends list).
    for (final u in candidates) {
      names.putIfAbsent(u, () => _synthName(u));
    }

    // Parse the geojson asset and build polygon geometry per county slug.
    // Coordinates are [lng, lat] pairs in GeoJSON; flutter_map needs LatLng.
    final geojson = jsonDecode(geojsonText) as Map<String, dynamic>;
    final featureList = (geojson['features'] as List<dynamic>?) ?? const [];
    final countyShapes = <_CountyShape>[];
    for (final f in featureList) {
      if (f is! Map) continue;
      final props = f['properties'] as Map<String, dynamic>?;
      final slug = props?['slug'] as String?;
      final name = props?['name'] as String?;
      if (slug == null || name == null) continue;
      final geom = f['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;
      final type = geom['type'] as String?;
      final coords = geom['coordinates'];
      final rings = <List<LatLng>>[];
      // We render only outer rings here — the heatmap doesn't need to honour
      // donut-hole holes for an at-a-glance view, and PolygonLayer's hole
      // support adds complexity for negligible visual gain at country scale.
      if (type == 'Polygon' && coords is List) {
        if (coords.isNotEmpty) {
          rings.add(_ringToLatLng(coords[0]));
        }
      } else if (type == 'MultiPolygon' && coords is List) {
        for (final poly in coords) {
          if (poly is List && poly.isNotEmpty) {
            rings.add(_ringToLatLng(poly[0]));
          }
        }
      }
      for (final ring in rings) {
        if (ring.length >= 3) {
          countyShapes.add(_CountyShape(slug: slug, name: name, ring: ring));
        }
      }
    }

    // Fetch the per-county leaderboard docs in batches via whereIn
    // (max 30 per query) rather than one read per slug. ~218 distinct slugs
    // therefore take ~8 round-trips instead of 218 — Firestore charges the
    // same per-doc read either way, but the wire latency is dramatically
    // lower and there's no thundering-herd of 218 concurrent gets.
    final distinctSlugs = countyShapes.map((c) => c.slug).toSet().toList();
    const lbBatchSize = 30;
    final lbBatches = <List<String>>[
      for (var i = 0; i < distinctSlugs.length; i += lbBatchSize)
        distinctSlugs.sublist(
            i, (i + lbBatchSize).clamp(0, distinctSlugs.length)),
    ];
    final countyLbCollection = db
        .collection('leaderboards')
        .doc('lifetime_by_county')
        .collection('counties');
    final lbBatchSnaps = await Future.wait(lbBatches.map((batch) async {
      try {
        final snap = await countyLbCollection
            .where(FieldPath.documentId, whereIn: batch)
            .get();
        return snap.docs;
      } catch (_) {
        return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      }
    }));
    final lbBySlug = <String, Map<String, dynamic>>{
      for (final docs in lbBatchSnaps)
        for (final d in docs) d.id: d.data(),
    };

    // For each county, find the leader within the candidate set (entries are
    // already sorted server-side by uniqueBoxes desc, totalPoints desc).
    final leaderBySlug = <String, _CountyLeader>{};
    for (final slug in distinctSlugs) {
      final lb = lbBySlug[slug];
      if (lb == null) continue;
      final entries = (lb['entries'] as List<dynamic>?) ?? const [];
      final e = pickCountyLeaderEntry(entries, candidates, widget.friendsOnly);
      if (e == null) continue;
      final entryUid = e['uid'] as String;
      final entryName = e['displayName'] as String?;
      leaderBySlug[slug] = _CountyLeader(
        uid: entryUid,
        displayName: (entryName != null && entryName.isNotEmpty)
            ? entryName
            : (names[entryUid] ?? _synthName(entryUid)),
        uniqueBoxes: (e['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
        totalPoints: (e['totalPoints'] as num?)?.toInt() ?? 0,
      );
    }

    // With the friends-only toggle off, leaders are arbitrary global players
    // who were never in the candidate set, so their names never came back from
    // the users/ batch above. Every county leaderboard entry carries a
    // server-maintained displayName (functions/src/_leaderboardUtils.ts), so
    // fold those in and the legend can label non-friends with no extra reads.
    // putIfAbsent keeps the fresher user-doc name for candidates.
    for (final leader in leaderBySlug.values) {
      names.putIfAbsent(leader.uid, () => leader.displayName);
    }

    return _HeatmapData(
      myUid: uid,
      candidates: candidates,
      shapes: countyShapes,
      leaderBySlug: leaderBySlug,
      displayNames: names,
      chosenColours: chosenColours,
      friendsOnly: widget.friendsOnly,
    );
  }

  /// Placeholder for a player whose name we can't resolve (deleted account, or
  /// an empty displayName). Mirrors the server's sanitiseName fallback in
  /// functions/src/onUserCreated.ts so the same user reads the same either way.
  static String _synthName(String uid) =>
      'Player_${uid.substring(0, uid.length.clamp(0, 6))}';

  static List<LatLng> _ringToLatLng(dynamic ring) {
    if (ring is! List) return const [];
    final out = <LatLng>[];
    for (final p in ring) {
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
        out.add(LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HeatmapData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 220,
            child: Center(
              child: CircularProgressIndicator(color: postalRed),
            ),
          );
        }
        if (snap.hasError || snap.data == null) {
          return SizedBox(
            height: 80,
            child: Center(
              child: Text(
                'County map unavailable',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          );
        }
        return _HeatmapView(data: snap.data!);
      },
    );
  }
}

class _HeatmapView extends StatefulWidget {
  final _HeatmapData data;
  const _HeatmapView({required this.data});

  @override
  State<_HeatmapView> createState() => _HeatmapViewState();
}

class _HeatmapViewState extends State<_HeatmapView> {
  static const LatLng _ukCentre = LatLng(54.5, -3.5);
  static const double _ukZoom = 4.6;

  final MapController _mapController = MapController();
  String? _selectedSlug;

  _HeatmapData get data => widget.data;

  Color _colourFor(String uid, BuildContext context) {
    return mapColourFor(
      uid: uid,
      isSelf: uid == data.myUid,
      chosenKey: data.chosenColours[uid],
    );
  }

  void _recenter() {
    _mapController.move(_ukCentre, _ukZoom);
    if (_selectedSlug != null) {
      setState(() => _selectedSlug = null);
    }
  }

  void _showLeaderSheet(BuildContext context, _CountyShape shape) {
    setState(() => _selectedSlug = shape.slug);
    final leader = data.leaderBySlug[shape.slug];
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(shape.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      )),
              const SizedBox(height: AppSpacing.sm),
              if (leader == null)
                Text(
                  // Friends-only: a missing leader means neither you nor any
                  // friend has claimed here. Global: nobody has at all.
                  data.friendsOnly
                      ? 'No claims here from you or your friends yet. Go grab the lead!'
                      : 'No claims here yet. Be the first!',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                )
              else ...[
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: _colourFor(leader.uid, context),
                      child: const Icon(Icons.emoji_events,
                          size: 16, color: Colors.white),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        leader.uid == data.myUid ? 'You lead' : leader.displayName,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${leader.uniqueBoxes} ${leader.uniqueBoxes == 1 ? 'box' : 'boxes'} · ${leader.totalPoints} pts',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.person_outline),
                    label: const Text('View profile'),
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(
                          UserProfilePage.route(leader.uid));
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _selectedSlug = null);
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final polygons = <Polygon>[];
    final hitPolygons = <Polygon, _CountyShape>{};
    final onSurface = Theme.of(context).colorScheme.onSurface;
    Polygon? selectedPoly;
    for (final shape in data.shapes) {
      final leader = data.leaderBySlug[shape.slug];
      final fill = leader == null
          ? onSurface.withValues(alpha: 0.18)
          : _colourFor(leader.uid, context).withValues(alpha: 0.55);
      final isSelected = shape.slug == _selectedSlug;
      final poly = Polygon(
        points: shape.ring,
        color: fill,
        borderColor: onSurface.withValues(
            alpha: isSelected ? 0.95 : 0.45),
        borderStrokeWidth: isSelected ? 2.2 : 0.6,
      );
      hitPolygons[poly] = shape;
      if (isSelected) {
        // Defer adding the selected polygon so it paints on top of its
        // neighbours' borders and the thicker highlight stroke isn't
        // overdrawn.
        selectedPoly = poly;
      } else {
        polygons.add(poly);
      }
    }
    if (selectedPoly != null) polygons.add(selectedPoly);

    // Distinct uids that lead at least one county — used in the legend, self
    // first then ranked by how many counties they hold. With the friends-only
    // toggle off there can be hundreds of leaders, so ranking (rather than
    // alphabetical) keeps the truncated chip row meaningful.
    final orderedLeaders = orderLegendLeaders(
      data.leaderBySlug.values.map((l) => l.uid),
      myUid: data.myUid,
      displayNames: data.displayNames,
    );

    final hasUnclaimed = data.leaderBySlug.length <
        data.shapes.map((s) => s.slug).toSet().length;

    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _ukCentre,
              initialZoom: _ukZoom,
              minZoom: 4.2,
              maxZoom: 11,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom,
              ),
              onTap: (tapPos, latLng) {
                // Hit-test in-app rather than via PolygonLayer's tap support
                // (which differs across flutter_map versions): walk shapes
                // and pick the first whose outer ring contains the point.
                for (final entry in hitPolygons.entries) {
                  if (_pointInRing(latLng, entry.key.points)) {
                    _showLeaderSheet(context, entry.value);
                    return;
                  }
                }
              },
            ),
            children: [
              Container(
                  color:
                      Theme.of(context).colorScheme.surfaceContainerHighest),
              PolygonLayer(polygons: polygons),
            ],
          ),
        ),
        if (orderedLeaders.isNotEmpty)
          Positioned(
            left: AppSpacing.sm,
            right: 56 + AppSpacing.sm,
            bottom: kJamesStripClearance + AppSpacing.sm,
            child: _LegendOverlay(
              leaders: orderedLeaders,
              myUid: data.myUid,
              displayNames: data.displayNames,
              colourFor: (uid) => _colourFor(uid, context),
              showNoLeader: hasUnclaimed,
            ),
          ),
        Positioned(
          right: AppSpacing.sm,
          bottom: kJamesStripClearance + AppSpacing.sm,
          child: _RecenterButton(onPressed: _recenter),
        ),
      ],
    );
  }

  /// Even-odd ray cast on a polygon ring of [LatLng] points (lat=y, lng=x).
  static bool _pointInRing(LatLng p, List<LatLng> ring) {
    bool inside = false;
    final x = p.longitude;
    final y = p.latitude;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      final intersect = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }
}

/// Floating chip cluster overlaid on the heatmap. Compact, semi-translucent,
/// elevated above the map polygons. Horizontally scrolls when there are more
/// chips than fit between the left edge and the recenter button.
class _LegendOverlay extends StatelessWidget {
  final List<String> leaders;
  final String myUid;
  final Map<String, String> displayNames;
  final Color Function(String uid) colourFor;
  final bool showNoLeader;

  const _LegendOverlay({
    required this.leaders,
    required this.myUid,
    required this.displayNames,
    required this.colourFor,
    required this.showNoLeader,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown =
        leaders.length < _kMaxLegendChips ? leaders.length : _kMaxLegendChips;
    final hidden = leaders.length - shown;
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      color: scheme.surface.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < shown; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                _LegendChip(
                  colour: colourFor(leaders[i]),
                  // Every leader uid is in displayNames — candidates from the
                  // users/ batch, global leaders from their leaderboard entry.
                  label: leaders[i] == myUid
                      ? 'You'
                      : (displayNames[leaders[i]] ?? 'Unknown player'),
                ),
              ],
              if (hidden > 0) ...[
                if (shown > 0) const SizedBox(width: AppSpacing.sm),
                // No swatch: this chip stands in for many colours at once.
                _LegendChip(label: '+$hidden more'),
              ],
              if (showNoLeader) ...[
                if (shown > 0 || hidden > 0)
                  const SizedBox(width: AppSpacing.sm),
                _LegendChip(
                  colour: scheme.onSurface.withValues(alpha: 0.4),
                  label: 'No leader',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small circular "reset to UK overview" affordance. Filled-tonal styling so it
/// reads as a control without competing with the heatmap colours.
class _RecenterButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _RecenterButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      shape: const CircleBorder(),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: IconButton(
        tooltip: 'Reset to UK',
        icon: const Icon(Icons.center_focus_strong_outlined),
        onPressed: onPressed,
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  /// Null renders the label alone — used by the "+N more" chip, which stands
  /// in for several players and so has no single colour to show.
  final Color? colour;
  final String label;
  const _LegendChip({this.colour, required this.label});

  @override
  Widget build(BuildContext context) {
    final swatch = colour;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (swatch != null) ...[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: swatch,
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.45),
                  width: 0.5),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Text(label,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _HeatmapData {
  final String myUid;
  final Set<String> candidates;
  final List<_CountyShape> shapes;
  final Map<String, _CountyLeader> leaderBySlug;
  final Map<String, String> displayNames;
  final Map<String, String> chosenColours;
  final bool friendsOnly;

  const _HeatmapData({
    required this.myUid,
    required this.candidates,
    required this.shapes,
    required this.leaderBySlug,
    required this.displayNames,
    required this.chosenColours,
    required this.friendsOnly,
  });
}

class _CountyShape {
  final String slug;
  final String name;
  final List<LatLng> ring;
  const _CountyShape({
    required this.slug,
    required this.name,
    required this.ring,
  });
}

class _CountyLeader {
  final String uid;
  final String displayName;
  final int uniqueBoxes;
  final int totalPoints;
  const _CountyLeader({
    required this.uid,
    required this.displayName,
    required this.uniqueBoxes,
    required this.totalPoints,
  });
}

