import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/theme.dart';

import './compass.dart';
import './fuzzy_compass.dart';

enum NearbyStage { initial, searching, results }

class Nearby extends StatefulWidget {
  const Nearby({super.key});

  @override
  NearbyState createState() => NearbyState();
}

class NearbyState extends State<Nearby> {
  int _count = 0;
  int _maxPoints = 0;
  int _minPoints = 0;
  int _EIIR = 0;
  int _GR = 0;
  int _GVR = 0;
  int _GVIR = 0;
  int _VR = 0;
  int _EVIIR = 0;
  int _EVIIIR = 0;

  int nne = 0;
  int ne = 0;
  int ene = 0;
  int e = 0;
  int ese = 0;
  int se = 0;
  int sse = 0;
  int s = 0;
  int ssw = 0;
  int sw = 0;
  int wsw = 0;
  int w = 0;
  int wnw = 0;
  int nw = 0;
  int nnw = 0;
  int n = 0;

  double? _direction;
  NearbyStage currentStage = NearbyStage.initial;

  static const Map<String, String> _monarchLabels = {
    'EIIR': 'Elizabeth II (1952–2022)',
    'CIIIR': 'Charles III (2022–)',
    'GVIR': 'George VI (1936–1952)',
    'GVR': 'George V (1910–1936)',
    'EVIIIR': 'Edward VIII (1936)',
    'EVIIR': 'Edward VII (1901–1910)',
    'VR': 'Victoria (1840–1901)',
    'GR': 'George (generic)',
  };

  static const Map<String, Color> _monarchColors = {
    'EIIR': postalRed,
    'CIIIR': postalRed,
    'GVIR': Colors.indigo,
    'GVR': Colors.teal,
    'EVIIIR': postalGold,
    'EVIIR': Colors.deepPurple,
    'VR': Colors.amber,
    'GR': Colors.blueGrey,
  };

  static const Set<String> _rareMonarchs = {'VR', 'EVIIR', 'EVIIIR'};

  @override
  void initState() {
    super.initState();
    FlutterCompass.events?.listen((CompassEvent event) {
      if (mounted) setState(() => _direction = event.heading);
    });
  }

  final HttpsCallable callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');

  Future<Position> getPosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied.');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission permanently denied. Enable it in Settings.');
    }
    return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  Future<void> _startSearch() async {
    setState(() => currentStage = NearbyStage.searching);
    try {
      final position = await getPosition();
      final result = await callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': 540,
      });
      setState(() {
        _count = result.data['counts']['total'] ?? 0;
        _maxPoints = result.data['points']['max'] ?? 0;
        _minPoints = result.data['points']['min'] ?? 0;
        currentStage = NearbyStage.results;
        nne = result.data['compass']['NNE'] ?? 0;
        ne = result.data['compass']['NE'] ?? 0;
        ene = result.data['compass']['ENE'] ?? 0;
        e = result.data['compass']['E'] ?? 0;
        ese = result.data['compass']['ESE'] ?? 0;
        se = result.data['compass']['SE'] ?? 0;
        sse = result.data['compass']['SSE'] ?? 0;
        s = result.data['compass']['S'] ?? 0;
        ssw = result.data['compass']['SSW'] ?? 0;
        sw = result.data['compass']['SW'] ?? 0;
        wsw = result.data['compass']['WSW'] ?? 0;
        w = result.data['compass']['W'] ?? 0;
        wnw = result.data['compass']['WNW'] ?? 0;
        nw = result.data['compass']['NW'] ?? 0;
        nnw = result.data['compass']['NNW'] ?? 0;
        n = result.data['compass']['N'] ?? 0;
        _EIIR = result.data['counts']['EIIR'] ?? 0;
        _GR = result.data['counts']['GR'] ?? 0;
        _GVR = result.data['counts']['GVR'] ?? 0;
        _GVIR = result.data['counts']['GVIR'] ?? 0;
        _VR = result.data['counts']['VR'] ?? 0;
        _EVIIR = result.data['counts']['EVIIR'] ?? 0;
        _EVIIIR = result.data['counts']['EVIIIR'] ?? 0;
      });
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase functions error: ${e.code} ${e.message}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not fetch postboxes. Please try again.'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
      setState(() => currentStage = NearbyStage.initial);
    } catch (e) {
      debugPrint('Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
      setState(() => currentStage = NearbyStage.initial);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (currentStage) {
      case NearbyStage.initial:
        return _buildInitial(context);
      case NearbyStage.searching:
        return _buildSearching(context);
      case NearbyStage.results:
        return _buildResults(context);
    }
  }

  Widget _buildInitial(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_searching,
                size: 80, color: Colors.grey.shade300),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Find nearby postboxes',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Scan within 540m to see which postboxes are around you.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _startSearch,
              icon: const Icon(Icons.search),
              label: const Text('Find nearby postboxes'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearching(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: postalRed),
          SizedBox(height: AppSpacing.md),
          Text('Scanning 540m radius...'),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final compassMap = <String, int>{
      'N': n, 'NNE': nne, 'NE': ne, 'ENE': ene, 'E': e, 'ESE': ese,
      'SE': se, 'SSE': sse, 'S': s, 'SSW': ssw, 'SW': sw, 'WSW': wsw,
      'W': w, 'WNW': wnw, 'NW': nw, 'NNW': nnw,
    };

    final monarchEntries = <MapEntry<String, int>>[
      MapEntry('EIIR', _EIIR),
      MapEntry('GVIR', _GVIR),
      MapEntry('GVR', _GVR),
      MapEntry('EVIIIR', _EVIIIR),
      MapEntry('EVIIR', _EVIIR),
      MapEntry('VR', _VR),
      MapEntry('GR', _GR),
    ].where((e) => e.value > 0).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      children: [
        // Summary card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: postalRed.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.location_on, color: postalRed),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_count postbox${_count == 1 ? '' : 'es'} nearby',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      if (_count > 0)
                        Text(
                          _maxPoints == _minPoints
                              ? 'Worth $_maxPoints pts'
                              : 'Worth $_minPoints–$_maxPoints pts',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _startSearch,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Empty state
        if (_count == 0)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              children: [
                Icon(Icons.location_off, size: 60, color: Colors.grey.shade300),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'No postboxes found within 540m',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Try a different location.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          ),

        // Monarch breakdown
        if (monarchEntries.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Text(
              'Postbox types',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          ...monarchEntries.map((e) => _monarchCard(context, e.key, e.value)),
        ],

        // Compasses
        if (_count > 0) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
            child: Text(
              'Rough directions',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          FuzzyCompass(
            compassCounts: compassMap,
            headingDegrees: _direction,
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Transform.rotate(
              angle: ((_direction ?? 0) * (pi / 180) * -1),
              child: Compass(
                n: n, nne: nne, ne: ne, ene: ene, e: e, ese: ese,
                se: se, sse: sse, s: s, ssw: ssw, sw: sw, wsw: wsw,
                w: w, wnw: wnw, nw: nw, nnw: nnw,
                rotation: 0 - ((_direction ?? 0) * (pi / 180) * -1),
              ),
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  Widget _monarchCard(BuildContext context, String code, int count) {
    final label = _monarchLabels[code] ?? code;
    final color = _monarchColors[code] ?? postalRed;
    final isRare = _rareMonarchs.contains(code);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha:0.12),
          child: Text(
            '$count',
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(label),
        subtitle: Text(code),
        trailing: isRare
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star, size: 14, color: postalGold),
                  const SizedBox(width: 2),
                  Text(
                    'Rare',
                    style: TextStyle(
                        color: postalGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}
