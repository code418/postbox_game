import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

class NominatimResult {
  final String displayName;
  final LatLng location;

  const NominatimResult({required this.displayName, required this.location});
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Thin async wrapper around the OSM Nominatim search endpoint.
///
/// Usage policy: https://operations.osmfoundation.org/policies/nominatim/
///  - Maximum 1 request per second from a single client → enforced via
///    [_lastCallAt] delay.
///  - A descriptive User-Agent must be sent with every request.
///
/// TODO: Read the version string from pubspec.yaml at build time (e.g. via a
///       generated `version.dart`); for now it is hard-coded as 1.0.
///
/// Cancel-friendliness: the current implementation does not support
/// cancellation. For a future improvement, accept a `CancellationToken` (or
/// expose an `AbortController`-style API) and check it before and after the
/// `await client.get(...)` call. The `http` package itself does not natively
/// support cancellation; the common pattern is to use `http_client_helper` or
/// wrap in a `Completer` that is completed with a `CancellationException`.
class NominatimService {
  static const String _userAgent = 'postbox-game/1.0 (richard@agilepixel.io)';
  static const String _baseUrl = 'https://nominatim.openstreetmap.org/search';
  static const Duration _minInterval = Duration(seconds: 1);

  final http.Client _client;

  /// Timestamp of the last HTTP call (null = no call yet).
  DateTime? _lastCallAt;

  /// True when [_client] was created by this instance and so should be
  /// closed in [close]. False when the caller supplied a client (e.g. test
  /// stubs whose lifecycle belongs to the test).
  final bool _ownsClient;

  NominatimService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Releases the underlying HTTP client's connection pool. Safe to call
  /// multiple times. Callers that create their own [NominatimService] should
  /// call this from their `dispose` so screen reopens don't leak clients.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// Search OSM Nominatim. Returns up to 5 results, UK-biased.
  ///
  /// Returns an empty list when [query] is blank or when Nominatim returns no
  /// matches. Throws on network errors or non-2xx HTTP responses.
  Future<List<NominatimResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    // Enforce 1 rps client-side throttle. Reserve the next slot *before*
    // awaiting so two concurrent search() calls fire 1 s apart, not both at
    // the same instant. The previous version updated _lastCallAt only after
    // the await: a second call entering during the first call's wait would
    // see the unchanged _lastCallAt and compute its own wait against the
    // same anchor, ending the wait at the same wall-clock moment as the
    // first — silently violating the OSM 1 rps usage policy.
    final now = DateTime.now();
    final earliestNext =
        _lastCallAt == null ? now : _lastCallAt!.add(_minInterval);
    final nextSlot = earliestNext.isAfter(now) ? earliestNext : now;
    _lastCallAt = nextSlot;
    final wait = nextSlot.difference(now);
    if (wait > Duration.zero) {
      await Future.delayed(wait);
    }

    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'q': trimmed,
      'format': 'json',
      'countrycodes': 'gb',
      'limit': '5',
      'addressdetails': '0',
    });

    final response = await _client.get(
      uri,
      headers: {'User-Agent': _userAgent},
    );

    if (response.statusCode != 200) {
      throw Exception('Nominatim error: ${response.statusCode}');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw Exception('Nominatim returned non-JSON response');
    }

    if (decoded is! List) {
      throw Exception('Nominatim returned unexpected JSON shape');
    }

    return decoded.map((dynamic item) {
      final map = item as Map<String, dynamic>;
      return NominatimResult(
        displayName: map['display_name'] as String,
        location: LatLng(
          double.parse(map['lat'] as String),
          double.parse(map['lon'] as String),
        ),
      );
    }).toList();
  }
}
