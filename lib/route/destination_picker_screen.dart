import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/route/nominatim_service.dart';
import 'package:postbox_game/route/route_preview_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';

/// Allows the user to pick a destination by tapping on a map or by searching
/// for an address.
///
/// On init, acquires the user's current GPS position and centres the map
/// there. A single tap drops (or moves) a destination pin. Once a pin has
/// been placed the "Set destination" button becomes active and navigates to
/// [RoutePreviewScreen].
///
/// An address search bar at the top of the screen queries OSM Nominatim
/// (debounced at 500 ms). Tapping a result drops the pin and centres the map.
///
/// [initialPosition] can be injected for testing (bypasses the real
/// [getPosition] call). When null the screen calls [getPosition] itself.
///
/// [nominatimService] can be injected for testing (bypasses real HTTP calls).
class DestinationPickerScreen extends StatefulWidget {
  /// Optional pre-resolved position — used in widget tests so the screen
  /// can be pumped without a real GPS fix.
  final LatLng? initialPosition;

  /// Optional Nominatim service — used in widget tests to inject a mock.
  final NominatimService? nominatimService;

  const DestinationPickerScreen({
    super.key,
    this.initialPosition,
    this.nominatimService,
  });

  @override
  State<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState extends State<DestinationPickerScreen> {
  /// The user's current position, resolved on init.
  LatLng? _userPosition;

  /// The destination the user has tapped on the map.
  LatLng? _pickedDestination;

  /// User-friendly label for the picked destination (from Nominatim, when the
  /// user chose a result from the search list). Null when the user tapped the
  /// map directly.
  String? _pickedDestinationLabel;

  /// Non-null when we failed to acquire the user's position.
  String? _locationError;

  // ── Search ────────────────────────────────────────────────────────────────

  late final NominatimService _nominatimService;
  final TextEditingController _searchController = TextEditingController();
  final MapController _mapController = MapController();

  /// Current list of search results (empty when the search field is blank or
  /// no results were found).
  List<NominatimResult> _searchResults = const [];

  /// True while a Nominatim query is in-flight.
  bool _isSearching = false;

  /// Non-null when the last search attempt produced an error.
  String? _searchError;

  /// Timer used to debounce search-field input (500 ms).
  Timer? _debounceTimer;

  /// True when we created the NominatimService ourselves (and so are
  /// responsible for closing its HTTP client). False when the caller
  /// injected one (e.g. tests) and owns its lifecycle.
  late final bool _ownsNominatimService;

  @override
  void initState() {
    super.initState();
    _ownsNominatimService = widget.nominatimService == null;
    _nominatimService = widget.nominatimService ?? NominatimService();
    if (widget.initialPosition != null) {
      // Injected for tests — skip real GPS.
      _userPosition = widget.initialPosition;
    } else {
      _acquirePosition();
    }
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    // Cancel the debounced search so a fast back-navigation doesn't fire
    // a Nominatim HTTP request whose result we'll immediately throw away —
    // a wasted slot in the 1-rps throttle and a useless network round-trip.
    _debounceTimer?.cancel();
    _searchController.dispose();
    _mapController.dispose();
    if (_ownsNominatimService) _nominatimService.close();
    super.dispose();
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

  // ── Search handlers ───────────────────────────────────────────────────────

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    final query = _searchController.text;
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = const [];
        _searchError = null;
        _isSearching = false;
      });
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _runSearch(query);
    });
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) return;
    setState(() {
      _isSearching = true;
      _searchError = null;
    });
    try {
      final results = await _nominatimService.search(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchResults = const [];
        _isSearching = false;
        _searchError = 'Address search failed. Check your connection.';
      });
    }
  }

  void _onSearchResultTap(NominatimResult result) {
    setState(() {
      _pickedDestination = result.location;
      _pickedDestinationLabel = result.displayName;
      _searchResults = const [];
      _searchError = null;
    });
    // Clear the text field and collapse the results list.
    _searchController.clear();
    // Move the map to the chosen location.
    try {
      _mapController.move(result.location, 15.0);
    } catch (_) {
      // Controller may not be attached if the map hasn't rendered yet.
    }
  }

  // ── Map tap ───────────────────────────────────────────────────────────────

  void _onMapTap(TapPosition _, LatLng point) {
    setState(() {
      _pickedDestination = point;
      // A raw map tap clears any Nominatim-derived label.
      _pickedDestinationLabel = null;
    });
  }

  void _onSetDestination() {
    if (_userPosition == null || _pickedDestination == null) return;
    final session = RouteSession(
      start: _userPosition!,
      destination: _pickedDestination!,
      destinationLabel: _pickedDestinationLabel,
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

    // Happy path — search bar + map + bottom panel.
    return Column(
      children: [
        _SearchBar(
          controller: _searchController,
          isSearching: _isSearching,
          results: _searchResults,
          error: _searchError,
          onResultTap: _onSearchResultTap,
        ),
        Expanded(
          child: PostboxMap(
            center: _userPosition!,
            mapController: _mapController,
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
          destinationLabel: _pickedDestinationLabel,
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
// Search bar
// ---------------------------------------------------------------------------

/// Address search bar with debounced Nominatim queries and an inline result
/// list that overlays the map below.
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isSearching;
  final List<NominatimResult> results;
  final String? error;
  final ValueChanged<NominatimResult> onResultTap;

  const _SearchBar({
    required this.controller,
    required this.isSearching,
    required this.results,
    required this.onResultTap,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search text field.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search address…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: isSearching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: postalRed,
                        ),
                      ),
                    )
                  : controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: controller.clear,
                          tooltip: 'Clear search',
                        )
                      : null,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                vertical: AppSpacing.sm,
                horizontal: AppSpacing.sm,
              ),
            ),
          ),
        ),
        // Inline error message.
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.error),
            ),
          ),
        // Results list — rendered inline so it doesn't float over the map as
        // an overlay, which would require a more complex Stack/Overlay setup.
        if (results.isNotEmpty)
          Material(
            elevation: 2,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = results[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_on_outlined, size: 18),
                  title: Text(
                    r.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () => onResultTap(r),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom panel
// ---------------------------------------------------------------------------

class _PickedLocationPanel extends StatelessWidget {
  final LatLng? pickedDestination;
  final String? destinationLabel;
  final VoidCallback? onSetDestination;

  const _PickedLocationPanel({
    required this.pickedDestination,
    required this.onSetDestination,
    this.destinationLabel,
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
                            child: destinationLabel != null
                                ? Text(
                                    destinationLabel!,
                                    style: Theme.of(context).textTheme.bodySmall,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : Text(
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
