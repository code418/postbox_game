import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/theme.dart';

/// A small, offline map of UK counties for the "Your Postboxes Unpacked"
/// cards: county outlines from `assets/uk_counties_simplified.geojson`
/// (the county heatmap's asset) with some counties lit up.
///
/// It never shows anything finer than a county, which keeps it within the
/// recap's privacy rule (no locations): a card can say "this was in Bristol"
/// without a street or a pin.
class UkCountyMap extends StatefulWidget {
  const UkCountyMap({
    super.key,
    required this.highlights,
    this.focus = const {},
    this.color = postalGold,
  });

  /// County name → strength, 0 (faint) to 1 (brightest). Names match the
  /// postbox docs' `county` field, which comes from the same ONS source.
  final Map<String, double> highlights;

  /// When not empty, the map zooms to these counties' region (with plenty of
  /// surroundings for context) instead of showing the whole UK.
  final Set<String> focus;

  final Color color;

  @override
  State<UkCountyMap> createState() => _UkCountyMapState();
}

/// Lower-case, non-alphanumerics to "-": how county names are compared, so
/// "Bristol, City of" and "bristol-city-of" match.
@visibleForTesting
String countyKey(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');

class _CountyShape {
  _CountyShape(this.key, this.rings) : bounds = _boundsOf(rings);
  final String key;
  final List<List<Offset>> rings;
  final Rect bounds;

  static Rect _boundsOf(List<List<Offset>> rings) {
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    for (final ring in rings) {
      for (final p in ring) {
        l = math.min(l, p.dx);
        t = math.min(t, p.dy);
        r = math.max(r, p.dx);
        b = math.max(b, p.dy);
      }
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

// Longitude is squeezed by cos(54.5°), the UK's middle latitude, so shapes
// aren't stretched east-west; y is -latitude so north is up.
const double _kLonScale = 0.5807;

List<_CountyShape> _parseShapes(String text) {
  final features =
      ((jsonDecode(text) as Map<String, dynamic>)['features'] as List?) ??
          const [];
  final shapes = <_CountyShape>[];
  List<Offset> ring(List<dynamic> pts) => [
        for (final p in pts)
          if (p is List && p.length >= 2)
            Offset((p[0] as num).toDouble() * _kLonScale,
                -(p[1] as num).toDouble()),
      ];
  for (final f in features) {
    if (f is! Map) continue;
    final name = (f['properties'] as Map?)?['name'];
    final geometry = f['geometry'] as Map?;
    if (name is! String || geometry == null) continue;
    final type = geometry['type'];
    final coords = geometry['coordinates'];
    final rings = <List<Offset>>[];
    if (type == 'Polygon' && coords is List && coords.isNotEmpty) {
      rings.add(ring(coords.first as List)); // outer ring only
    } else if (type == 'MultiPolygon' && coords is List) {
      for (final poly in coords) {
        if (poly is List && poly.isNotEmpty) {
          rings.add(ring(poly.first as List));
        }
      }
    }
    if (rings.isNotEmpty) shapes.add(_CountyShape(countyKey(name), rings));
  }
  return shapes;
}

Future<List<_CountyShape>>? _shapesFuture;

/// Loaded once per process and shared by every map.
Future<List<_CountyShape>> _loadShapes() => _shapesFuture ??= rootBundle
        .loadString('assets/uk_counties_simplified.geojson')
        .then((text) => compute(_parseShapes, text))
        .catchError((Object e) {
      _shapesFuture = null; // let a later map retry
      debugPrint('UkCountyMap: could not load counties: $e');
      return <_CountyShape>[];
    });

class _UkCountyMapState extends State<UkCountyMap> {
  List<_CountyShape>? _shapes;

  @override
  void initState() {
    super.initState();
    _loadShapes().then((s) {
      if (mounted) setState(() => _shapes = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shapes = _shapes;
    if (shapes == null || shapes.isEmpty) return const SizedBox.expand();
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CountyMapPainter(
          shapes: shapes,
          highlights: {
            for (final e in widget.highlights.entries)
              countyKey(e.key): e.value.clamp(0.0, 1.0),
          },
          focus: {for (final f in widget.focus) countyKey(f)},
          color: widget.color,
        ),
      ),
    );
  }
}

class _CountyMapPainter extends CustomPainter {
  _CountyMapPainter({
    required this.shapes,
    required this.highlights,
    required this.focus,
    required this.color,
  });

  final List<_CountyShape> shapes;
  final Map<String, double> highlights;
  final Set<String> focus;
  final Color color;

  Rect _view() {
    Rect? all;
    Rect? focused;
    for (final s in shapes) {
      all = all == null ? s.bounds : all.expandToInclude(s.bounds);
      if (focus.contains(s.key)) {
        focused =
            focused == null ? s.bounds : focused.expandToInclude(s.bounds);
      }
    }
    if (focused == null) return all!;
    // A region, not a close-up: at least ~2.5° of longitude and ~1.8° of
    // latitude around the focus, plus a margin.
    final w = math.max(focused.width, 2.5 * _kLonScale) * 1.6;
    final h = math.max(focused.height, 1.8) * 1.6;
    return Rect.fromCenter(center: focused.center, width: w, height: h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final view = _view();
    final scale = math.min(size.width / view.width, size.height / view.height);
    // Contain the view in the box, anchored bottom-right.
    final dx = size.width - view.width * scale;
    final dy = size.height - view.height * scale;
    Offset map(Offset p) =>
        Offset(dx + (p.dx - view.left) * scale, dy + (p.dy - view.top) * scale);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final base = Paint()..color = Colors.white.withValues(alpha: 0.08);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withValues(alpha: 0.22);
    final lit = <(Path, double)>[];
    for (final s in shapes) {
      if (!s.bounds.overlaps(view)) continue;
      final path = Path();
      for (final ring in s.rings) {
        if (ring.length < 3) continue;
        path.addPolygon([for (final p in ring) map(p)], true);
      }
      final strength = highlights[s.key];
      if (strength != null) {
        lit.add((path, strength));
      } else {
        canvas.drawPath(path, base);
        canvas.drawPath(path, edge);
      }
    }
    // Lit counties last, so their outlines sit on top of their neighbours'.
    for (final (path, strength) in lit) {
      canvas.drawPath(path,
          Paint()..color = color.withValues(alpha: 0.3 + 0.65 * strength));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CountyMapPainter old) =>
      old.shapes != shapes ||
      !mapEquals(old.highlights, highlights) ||
      !setEquals(old.focus, focus) ||
      old.color != color;
}
