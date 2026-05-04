import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_profile_page.dart';

/// UK county heatmap showing which of (the user + their friends) leads each
/// county's lifetime ranking. Colours each polygon by the leading uid; the
/// signed-in user's own colour is fixed (postal red); friends use a
/// deterministic palette by uid hash.
///
/// The map intentionally has no tile layer — the heatmap is the content, a
/// base map would distract and incur OSM tile traffic for no benefit.
class CountyHeatmap extends StatefulWidget {
  const CountyHeatmap({super.key});

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
    // sheet can show "Alex" rather than a UID. One read per friend; cached
    // for the lifetime of the widget.
    final candidates = <String>{uid, ...friends};
    final nameDocs = await Future.wait(candidates.map(
      (u) => db.collection('users').doc(u).get(),
    ));
    final names = <String, String>{};
    for (final d in nameDocs) {
      final n = d.data()?['displayName'] as String?;
      names[d.id] = (n == null || n.isEmpty)
          ? 'Player_${d.id.substring(0, d.id.length.clamp(0, 6))}'
          : n;
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

    // Fetch the per-county leaderboard docs in parallel — one read per
    // distinct slug present in the geojson. ~218 reads worst case.
    final distinctSlugs = countyShapes.map((c) => c.slug).toSet().toList();
    final leaderboardSnaps = await Future.wait(distinctSlugs.map(
      (s) => db
          .collection('leaderboards')
          .doc('lifetime_by_county')
          .collection('counties')
          .doc(s)
          .get(),
    ));

    // For each county, find the leader within the candidate set (entries are
    // already sorted server-side by uniqueBoxes desc, totalPoints desc).
    final leaderBySlug = <String, _CountyLeader>{};
    for (var i = 0; i < distinctSlugs.length; i++) {
      final lb = leaderboardSnaps[i].data();
      if (lb == null) continue;
      final entries = (lb['entries'] as List<dynamic>?) ?? const [];
      for (final e in entries) {
        if (e is! Map) continue;
        final entryUid = e['uid'] as String?;
        if (entryUid == null || !candidates.contains(entryUid)) continue;
        leaderBySlug[distinctSlugs[i]] = _CountyLeader(
          uid: entryUid,
          displayName: (e['displayName'] as String?) ??
              names[entryUid] ??
              'Unknown',
          uniqueBoxes:
              (e['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
          totalPoints: (e['totalPoints'] as num?)?.toInt() ?? 0,
        );
        break;
      }
    }

    return _HeatmapData(
      myUid: uid,
      candidates: candidates,
      shapes: countyShapes,
      leaderBySlug: leaderBySlug,
      displayNames: names,
    );
  }

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

class _HeatmapView extends StatelessWidget {
  final _HeatmapData data;
  const _HeatmapView({required this.data});

  Color _colourFor(String uid, BuildContext context) {
    if (uid == data.myUid) return postalRed;
    // Stable colour per friend uid via a low-bit hash into a fixed palette.
    final palette = <Color>[
      Colors.indigo, Colors.teal, Colors.deepOrange, Colors.purple,
      Colors.green.shade700, Colors.brown, Colors.cyan.shade700,
      Colors.pink.shade400, Colors.amber.shade800, Colors.blueGrey,
    ];
    final h = uid.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
    return palette[h % palette.length];
  }

  void _showLeaderSheet(BuildContext context, _CountyShape shape) {
    final leader = data.leaderBySlug[shape.slug];
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
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
                  'No friend has claimed in this county yet.',
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
                      Navigator.of(context).pop();
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final polygons = <Polygon>[];
    final hitPolygons = <Polygon, _CountyShape>{};
    for (final shape in data.shapes) {
      final leader = data.leaderBySlug[shape.slug];
      final fill = leader == null
          ? Colors.grey.withValues(alpha: 0.18)
          : _colourFor(leader.uid, context).withValues(alpha: 0.55);
      final poly = Polygon(
        points: shape.ring,
        color: fill,
        borderColor: Colors.black.withValues(alpha: 0.25),
        borderStrokeWidth: 0.6,
      );
      polygons.add(poly);
      hitPolygons[poly] = shape;
    }

    // Distinct friend uids that lead at least one county — used in legend.
    final leaderUids = <String>{
      for (final l in data.leaderBySlug.values) l.uid,
    };
    final orderedLeaders = leaderUids.toList()
      ..sort((a, b) => a == data.myUid ? -1 : (b == data.myUid ? 1 : 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 320,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FlutterMap(
              options: MapOptions(
                initialCenter: const LatLng(54.5, -3.5),
                initialZoom: 4.6,
                minZoom: 4.2,
                maxZoom: 8,
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
                Container(color: const Color(0xFFF6F4F0)),
                PolygonLayer(polygons: polygons),
              ],
            ),
          ),
        ),
        if (orderedLeaders.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 4,
            children: [
              for (final uid in orderedLeaders.take(8))
                _LegendChip(
                  colour: _colourFor(uid, context),
                  label: uid == data.myUid
                      ? 'You'
                      : (data.displayNames[uid] ?? 'Friend'),
                ),
              if (data.leaderBySlug.length <
                  data.shapes.map((s) => s.slug).toSet().length)
                _LegendChip(
                  colour: Colors.grey.withValues(alpha: 0.4),
                  label: 'No leader',
                ),
            ],
          ),
        ],
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

class _LegendChip extends StatelessWidget {
  final Color colour;
  final String label;
  const _LegendChip({required this.colour, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(
                color: Colors.black.withValues(alpha: 0.25), width: 0.5),
          ),
        ),
        const SizedBox(width: 4),
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

  const _HeatmapData({
    required this.myUid,
    required this.candidates,
    required this.shapes,
    required this.leaderBySlug,
    required this.displayNames,
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

