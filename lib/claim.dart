import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/theme.dart';

enum ClaimStage { initial, searching, results, empty, claimed }

class Claim extends StatefulWidget {
  const Claim({super.key});

  @override
  ClaimState createState() => ClaimState();
}

class ClaimState extends State<Claim> with SingleTickerProviderStateMixin {
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
  int _CIIIR = 0;
  int _claimedToday = 0;
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  int _pointsEarned = 0;
  bool _isClaiming = false;

  ClaimStage currentStage = ClaimStage.initial;

  late AnimationController _successController;
  late Animation<double> _successScale;

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

  static const Set<String> _rareMonarchs = {'EVIIIR', 'CIIIR'};
  static const Set<String> _historicMonarchs = {'VR', 'EVIIR'};

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

  @override
  void initState() {
    super.initState();
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successScale = CurvedAnimation(
      parent: _successController,
      curve: Curves.elasticOut,
    );
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
  }

  @override
  void dispose() {
    _successController.dispose();
    super.dispose();
  }

  final HttpsCallable _callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      FirebaseFunctions.instance.httpsCallable('startScoring');

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
      throw Exception('Location permission permanently denied. Enable in Settings.');
    }
    return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  Future<void> _startSearch() async {
    _distanceUnit = await AppPreferences.getDistanceUnit();
    setState(() => currentStage = ClaimStage.searching);
    try {
      final position = await _getPosition();
      final result = await _callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': 30,
      });
      setState(() {
        _count = result.data['counts']['total'] ?? 0;
        _maxPoints = result.data['points']['max'] ?? 0;
        _minPoints = result.data['points']['min'] ?? 0;
        _EIIR = result.data['counts']['EIIR'] ?? 0;
        _GR = result.data['counts']['GR'] ?? 0;
        _GVR = result.data['counts']['GVR'] ?? 0;
        _GVIR = result.data['counts']['GVIR'] ?? 0;
        _VR = result.data['counts']['VR'] ?? 0;
        _EVIIR = result.data['counts']['EVIIR'] ?? 0;
        _EVIIIR = result.data['counts']['EVIIIR'] ?? 0;
        _CIIIR = result.data['counts']['CIIIR'] ?? 0;
        _claimedToday = result.data['counts']['claimedToday'] ?? 0;
        currentStage = _count > 0 ? ClaimStage.results : ClaimStage.empty;
      });
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase functions error: ${e.code} ${e.message}');
      _showErrorSnackBar('Could not scan for postboxes. Please try again.');
      setState(() => currentStage = ClaimStage.initial);
    } catch (e) {
      debugPrint('Error scanning: $e');
      _showErrorSnackBar(e.toString().replaceFirst('Exception: ', ''));
      setState(() => currentStage = ClaimStage.initial);
    }
  }

  Future<void> _claimPostbox() async {
    setState(() => _isClaiming = true);
    HapticFeedback.mediumImpact();
    try {
      final position = await _getPosition();
      final result = await _claimCallable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
      });
      if (result.data?['allClaimedToday'] == true) {
        setState(() => _isClaiming = false);
        _showErrorSnackBar('Just claimed by someone else — refreshing...');
        await _startSearch();
        return;
      }
      final points = result.data?['points'] ?? 0;
      setState(() {
        _pointsEarned = points is int ? points : (points as num).toInt();
        _isClaiming = false;
        currentStage = ClaimStage.claimed;
      });
      _successController.forward(from: 0);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Claim error: ${e.code} ${e.message}');
      _showErrorSnackBar(e.message ?? 'Could not claim postbox.');
      setState(() => _isClaiming = false);
    } catch (e) {
      debugPrint('Claim error: $e');
      _showErrorSnackBar('Could not claim postbox. Please try again.');
      setState(() => _isClaiming = false);
    }
  }

  Widget _buildAllClaimedBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock, color: Colors.orange.shade700),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Already claimed today',
                  style: TextStyle(
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600),
                ),
                Text(
                  'Resets at midnight · London time',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.orange.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) {
    switch (currentStage) {
      case ClaimStage.initial:
        return _buildInitial(context);
      case ClaimStage.searching:
        return _buildSearching(context);
      case ClaimStage.results:
        return _buildResults(context);
      case ClaimStage.empty:
        return _buildEmpty(context);
      case ClaimStage.claimed:
        return _buildClaimed(context);
    }
  }

  Widget _buildInitial(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/postbox.svg',
              height: 100,
              colorFilter: const ColorFilter.mode(postalRed, BlendMode.srcIn),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Find a postbox to claim',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Stand within ${AppPreferences.formatShortDistance(30.0, _distanceUnit)} of a postbox, then tap below to check if you can claim it.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _startSearch,
              icon: const Icon(Icons.radar),
              label: const Text('Scan for postboxes nearby'),
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
          Text('Scanning within ${AppPreferences.formatShortDistance(30.0, _distanceUnit)}...'),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, size: 80, color: Colors.grey.shade400),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No postboxes found within ${AppPreferences.formatShortDistance(30.0, _distanceUnit)}',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Try moving closer to a postbox. They have exact locations.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _startSearch,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => setState(() => currentStage = ClaimStage.initial),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final monarchEntries = <MapEntry<String, int>>[
      MapEntry('EIIR', _EIIR),
      MapEntry('CIIIR', _CIIIR),
      MapEntry('GVIR', _GVIR),
      MapEntry('GVR', _GVR),
      MapEntry('EVIIIR', _EVIIIR),
      MapEntry('EVIIR', _EVIIR),
      MapEntry('VR', _VR),
      MapEntry('GR', _GR),
    ].where((e) => e.value > 0).toList();

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.md,
            bottom: 100,
          ),
          children: [
            _summaryCard(context),
            const SizedBox(height: AppSpacing.sm),
            ...monarchEntries.map((e) => _monarchCard(context, e.key, e.value)),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: OutlinedButton.icon(
                onPressed: _startSearch,
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan location'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          left: AppSpacing.md,
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          child: _claimedToday == _count
              ? _buildAllClaimedBanner(context)
              : AbsorbPointer(
                  absorbing: _isClaiming,
                  child: FilledButton.icon(
                    onPressed: _isClaiming ? null : _claimPostbox,
                    icon: _isClaiming
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(_isClaiming ? 'Claiming...' : 'Claim this postbox!'),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _summaryCard(BuildContext context) {
    final pointsText = _maxPoints == _minPoints
        ? '$_maxPoints pts'
        : '$_minPoints–$_maxPoints pts';
    return Card(
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
                    _claimedToday == _count
                        ? 'All $_count postbox${_count == 1 ? '' : 'es'} claimed today'
                        : _claimedToday > 0
                            ? '${_count - _claimedToday} of $_count available · $_claimedToday claimed today'
                            : '$_count postbox${_count == 1 ? '' : 'es'} within ${AppPreferences.formatShortDistance(30.0, _distanceUnit)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  Text(
                    'Worth $pointsText',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _monarchCard(BuildContext context, String code, int count) {
    final label = _monarchLabels[code] ?? code;
    final color = _monarchColors[code] ?? postalRed;

    Widget? trailing;
    if (_rareMonarchs.contains(code)) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 14, color: postalGold),
          const SizedBox(width: 2),
          Text('Rare',
              style: TextStyle(
                  color: postalGold, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      );
    } else if (_historicMonarchs.contains(code)) {
      trailing = Text('Historic',
          style: TextStyle(
              color: Colors.brown.shade400,
              fontSize: 12,
              fontWeight: FontWeight.w500));
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

  Widget _buildClaimed(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: _successScale,
              child: const Icon(
                Icons.check_circle,
                size: 100,
                color: Color(0xFF2E7D32),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Postbox claimed!',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_pointsEarned > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: postalGold.withValues(alpha:0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '+$_pointsEarned points',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: postalGold,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
            const SizedBox(height: AppSpacing.xxl),
            FilledButton.icon(
              onPressed: () => setState(() => currentStage = ClaimStage.initial),
              icon: const Icon(Icons.explore),
              label: const Text('Keep exploring'),
            ),
          ],
        ),
      ),
    );
  }
}
