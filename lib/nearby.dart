import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/theme.dart';

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
  int _eiir = 0;
  int _gr = 0;
  int _gvr = 0;
  int _gvir = 0;
  int _vr = 0;
  int _eviir = 0;
  int _eviiir = 0;
  int _ciiir = 0;
  int _claimedToday = 0;
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  DateTime? _lastScanned;

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
  StreamSubscription<CompassEvent>? _compassSubscription;
  NearbyStage currentStage = NearbyStage.initial;


  @override
  void initState() {
    super.initState();
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      if (mounted) setState(() => _direction = event.heading);
    });
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
  }

  @override
  void dispose() {
    _compassSubscription?.cancel();
    super.dispose();
  }

  final HttpsCallable callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');

  Future<Position> _getPosition() async {
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
    _distanceUnit = await AppPreferences.getDistanceUnit();
    setState(() => currentStage = NearbyStage.searching);
    try {
      final position = await _getPosition();
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
        _eiir = result.data['counts']['EIIR'] ?? 0;
        _gr = result.data['counts']['GR'] ?? 0;
        _gvr = result.data['counts']['GVR'] ?? 0;
        _gvir = result.data['counts']['GVIR'] ?? 0;
        _vr = result.data['counts']['VR'] ?? 0;
        _eviir = result.data['counts']['EVIIR'] ?? 0;
        _eviiir = result.data['counts']['EVIIIR'] ?? 0;
        _ciiir = result.data['counts']['CIIIR'] ?? 0;
        _claimedToday = result.data['counts']['claimedToday'] ?? 0;
        _lastScanned = DateTime.now();
      });
      if (mounted) {
        final box = _count == 1 ? 'postbox' : 'postboxes';
        final msg = _count > 0
            ? JamesMessages.nearbyFound(_count, box)
            : JamesMessages.nearbyNoneFound.resolve();
        JamesController.of(context).show(msg);
      }
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
        final msg = e.toString().contains('permission')
            ? JamesMessages.nearbyErrorPermission.resolve()
            : JamesMessages.nearbyErrorGeneral.resolve();
        JamesController.of(context).show(msg);
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
              'Scan within ${AppPreferences.formatDistance(540.0, _distanceUnit)} to see which postboxes are around you.',
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: postalRed),
          const SizedBox(height: AppSpacing.md),
          Text('Scanning ${AppPreferences.formatDistance(540.0, _distanceUnit)} radius...'),
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
      MapEntry('EIIR', _eiir),
      MapEntry('CIIIR', _ciiir),
      MapEntry('GVIR', _gvir),
      MapEntry('GVR', _gvr),
      MapEntry('EVIIIR', _eviiir),
      MapEntry('EVIIR', _eviir),
      MapEntry('VR', _vr),
      MapEntry('GR', _gr),
    ].where((e) => e.value > 0).toList();

    return RefreshIndicator(
      color: postalRed,
      onRefresh: _startSearch,
      child: AnimationLimiter(
      child: ListView(
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
                      if (_count > 0 && _claimedToday < _count)
                        Text(
                          _maxPoints == _minPoints
                              ? 'Worth $_maxPoints pts'
                              : 'Worth $_minPoints–$_maxPoints pts',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                      if (_lastScanned != null)
                        Text(
                          'Scanned at ${TimeOfDay.fromDateTime(_lastScanned!).format(context)}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.grey.shade500),
                        ),
                      if (_claimedToday > 0)
                        Row(
                          children: [
                            const Icon(Icons.lock_clock, size: 12, color: Colors.orange),
                            const SizedBox(width: 4),
                            Text(
                              '$_claimedToday claimed today',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.orange.shade700,
                                  ),
                            ),
                          ],
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
                  'No postboxes found within ${AppPreferences.formatDistance(540.0, _distanceUnit)}',
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
          ...monarchEntries.asMap().entries.map((entry) =>
            AnimationConfiguration.staggeredList(
              position: entry.key,
              duration: const Duration(milliseconds: 375),
              child: SlideAnimation(
                verticalOffset: 50,
                child: FadeInAnimation(
                  child: _monarchCard(context, entry.value.key, entry.value.value),
                ),
              ),
            )),
        ],

        // Compasses
        if (_count > 0) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
            child: Text(
              'Where to look',
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
        ],

      ],
    ),
      ),
    );
  }

  Widget _monarchCard(BuildContext context, String code, int count) {
    final label = MonarchInfo.labels[code] ?? code;
    final color = MonarchInfo.colors[code] ?? postalRed;

    Widget? trailing;
    if (MonarchInfo.rareCiphers.contains(code)) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 14, color: postalGold),
          const SizedBox(width: 2),
          Text(
            'Rare',
            style: TextStyle(
                color: postalGold, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      );
    } else if (MonarchInfo.historicCiphers.contains(code)) {
      trailing = Text(
        'Historic',
        style: TextStyle(
            color: Colors.brown.shade400,
            fontSize: 12,
            fontWeight: FontWeight.w500),
      );
    }

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Text(
            '$count',
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(label),
        subtitle: Text(code),
        trailing: trailing,
      ),
    );
  }
}
