import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/route/route_preview_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';

/// Allows the user to pick a destination by tapping on a map.
///
/// On init, acquires the user's current GPS position and centres the map
/// there. A single tap drops (or moves) a destination pin. Once a pin has
/// been placed the "Set destination" button becomes active and navigates to
/// [RoutePreviewScreen].
///
/// [initialPosition] can be injected for testing (bypasses the real
/// [getPosition] call). When null the screen calls [getPosition] itself.
class DestinationPickerScreen extends StatefulWidget {
  /// Optional pre-resolved position — used in widget tests so the screen
  /// can be pumped without a real GPS fix.
  final LatLng? initialPosition;

  const DestinationPickerScreen({super.key, this.initialPosition});

  @override
  State<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState extends State<DestinationPickerScreen> {
  /// The user's current position, resolved on init.
  LatLng? _userPosition;

  /// The destination the user has tapped on the map.
  LatLng? _pickedDestination;

  /// Non-null when we failed to acquire the user's position.
  String? _locationError;

  @override
  void initState() {
    super.initState();
    if (widget.initialPosition != null) {
      // Injected for tests — skip real GPS.
      _userPosition = widget.initialPosition;
    } else {
      _acquirePosition();
    }
  }

  Future<void> _acquirePosition() async {
    try {
      final pos = await getPosition();
      if (!mounted) return;
      setState(() => _userPosition = LatLng(pos.latitude, pos.longitude));
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      final bool isPermanentlyDenied = raw.contains('permanently denied');
      final bool isServicesDisabled = raw.contains('services are disabled');

      setState(() {
        if (isPermanentlyDenied) {
          _locationError =
              'Location permission permanently denied. Enable it in Settings.';
        } else if (isServicesDisabled) {
          _locationError = 'Location services are disabled.';
        } else {
          _locationError = 'Could not determine your location. Please try again.';
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locationError!),
          backgroundColor: Colors.red.shade700,
          action: isPermanentlyDenied
              ? SnackBarAction(
                  label: 'Open Settings',
                  textColor: Colors.white,
                  onPressed: Geolocator.openAppSettings,
                )
              : isServicesDisabled
                  ? SnackBarAction(
                      label: 'Open Settings',
                      textColor: Colors.white,
                      onPressed: Geolocator.openLocationSettings,
                    )
                  : null,
        ),
      );
    }
  }

  void _onMapTap(TapPosition _, LatLng point) {
    setState(() => _pickedDestination = point);
  }

  void _onSetDestination() {
    if (_userPosition == null || _pickedDestination == null) return;
    final session = RouteSession(
      start: _userPosition!,
      destination: _pickedDestination!,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RoutePreviewScreen(session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pick a destination')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // Still waiting for the GPS fix.
    if (_userPosition == null && _locationError == null) {
      return const Padding(
        padding: EdgeInsets.only(bottom: kJamesStripClearance),
        child: Center(child: CircularProgressIndicator(color: postalRed)),
      );
    }

    // Location error — show a retry prompt.
    if (_locationError != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: kJamesStripClearance),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.location_off,
                  size: 64,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.25),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  _locationError!,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: () {
                    setState(() => _locationError = null);
                    _acquirePosition();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Happy path — map + bottom panel.
    return Column(
      children: [
        Expanded(
          child: PostboxMap(
            center: _userPosition!,
            onTap: _onMapTap,
            markers: [
              userPositionMarker(_userPosition!),
              if (_pickedDestination != null)
                _destinationMarker(_pickedDestination!),
            ],
          ),
        ),
        _PickedLocationPanel(
          pickedDestination: _pickedDestination,
          onSetDestination:
              _pickedDestination != null ? _onSetDestination : null,
        ),
      ],
    );
  }

  /// A red pin marker for the chosen destination.
  Marker _destinationMarker(LatLng point) {
    return Marker(
      point: point,
      width: 40,
      height: 48,
      child: const _DestinationPin(),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom panel
// ---------------------------------------------------------------------------

class _PickedLocationPanel extends StatelessWidget {
  final LatLng? pickedDestination;
  final VoidCallback? onSetDestination;

  const _PickedLocationPanel({
    required this.pickedDestination,
    required this.onSetDestination,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Coordinate card
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: pickedDestination == null
                    ? Row(
                        children: [
                          Icon(Icons.touch_app,
                              size: 18,
                              color: cs.onSurface.withValues(alpha: 0.45)),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            'Tap the map to place a destination',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Icon(Icons.location_on,
                              size: 18, color: postalRed),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              '${pickedDestination!.latitude.toStringAsFixed(5)}, '
                              '${pickedDestination!.longitude.toStringAsFixed(5)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: onSetDestination,
              child: const Text('Set destination'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Destination pin widget
// ---------------------------------------------------------------------------

class _DestinationPin extends StatelessWidget {
  const _DestinationPin();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: postalRed,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: postalRed.withValues(alpha: 0.4),
                blurRadius: 6,
                spreadRadius: 1,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(Icons.flag, color: Colors.white, size: 18),
        ),
        // Stem
        Container(
          width: 3,
          height: 8,
          decoration: BoxDecoration(
            color: postalRed,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}
