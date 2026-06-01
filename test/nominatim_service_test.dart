// Tests for NominatimService.
//
// Uses a mock http.Client so no real network requests are made.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:postbox_game/route/nominatim_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal Nominatim JSON response list.
String _nominatimJson(List<Map<String, String>> items) {
  return jsonEncode(items.map((m) => {
    'display_name': m['display_name']!,
    'lat': m['lat']!,
    'lon': m['lon']!,
  }).toList());
}

const _sampleResults = [
  {
    'display_name': 'Buckingham Palace, Westminster, London, England, SW1A 1AA',
    'lat': '51.5014',
    'lon': '-0.1419',
  },
  {
    'display_name': 'Palace Road, London Borough of Bromley, London, England',
    'lat': '51.4052',
    'lon': '-0.0582',
  },
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('NominatimService', () {
    test('empty query returns [] without hitting the network', () async {
      bool wasCalled = false;
      final mockClient = MockClient((_) async {
        wasCalled = true;
        return http.Response('[]', 200);
      });

      final service = NominatimService(client: mockClient);
      final results = await service.search('');
      expect(results, isEmpty);
      expect(wasCalled, isFalse,
          reason: 'No HTTP call should be made for an empty query');
    });

    test('whitespace-only query returns [] without hitting the network',
        () async {
      bool wasCalled = false;
      final mockClient = MockClient((_) async {
        wasCalled = true;
        return http.Response('[]', 200);
      });

      final service = NominatimService(client: mockClient);
      final results = await service.search('   ');
      expect(results, isEmpty);
      expect(wasCalled, isFalse);
    });

    test('200 response is parsed into NominatimResult list', () async {
      final mockClient = MockClient((_) async {
        return http.Response(_nominatimJson(_sampleResults), 200);
      });

      final service = NominatimService(client: mockClient);
      final results = await service.search('Buckingham Palace');

      expect(results, hasLength(2));

      expect(results[0].displayName, contains('Buckingham Palace'));
      expect(results[0].location.latitude, closeTo(51.5014, 0.0001));
      expect(results[0].location.longitude, closeTo(-0.1419, 0.0001));

      expect(results[1].displayName, contains('Palace Road'));
    });

    test('skips malformed entries instead of failing the whole search',
        () async {
      // A response mixing valid results with malformed ones (null lat,
      // unparseable lon, missing display_name, out-of-range coords). Only the
      // two valid entries should survive — one bad row must not blank the rest.
      const mixed = '''
      [
        {"display_name": "Valid One", "lat": "51.5", "lon": "-0.12"},
        {"display_name": "Null lat", "lat": null, "lon": "-0.12"},
        {"display_name": "Bad lon", "lat": "51.5", "lon": "not-a-number"},
        {"lat": "51.5", "lon": "-0.12"},
        {"display_name": "Out of range", "lat": "120.0", "lon": "-0.12"},
        {"display_name": "Valid Two", "lat": "53.48", "lon": "-2.24"}
      ]''';
      final mockClient = MockClient((_) async => http.Response(mixed, 200));

      final service = NominatimService(client: mockClient);
      final results = await service.search('London');

      expect(results, hasLength(2));
      expect(results[0].displayName, 'Valid One');
      expect(results[1].displayName, 'Valid Two');
      expect(results[1].location.latitude, closeTo(53.48, 0.001));
    });

    test('empty JSON array returns empty list', () async {
      final mockClient = MockClient((_) async {
        return http.Response('[]', 200);
      });

      final service = NominatimService(client: mockClient);
      final results = await service.search('xyzzy nowhere');
      expect(results, isEmpty);
    });

    test('4xx HTTP status throws', () async {
      final mockClient = MockClient((_) async {
        return http.Response('Not Found', 404);
      });

      final service = NominatimService(client: mockClient);
      expect(
        () => service.search('London'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('404'),
          ),
        ),
      );
    });

    test('5xx HTTP status throws', () async {
      final mockClient = MockClient((_) async {
        return http.Response('Internal Server Error', 500);
      });

      final service = NominatimService(client: mockClient);
      expect(
        () => service.search('London'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('500'),
          ),
        ),
      );
    });

    test('non-JSON 200 response throws', () async {
      final mockClient = MockClient((_) async {
        return http.Response('<html>error</html>', 200);
      });

      final service = NominatimService(client: mockClient);
      expect(
        () => service.search('London'),
        throwsA(isA<Exception>()),
      );
    });

    test('User-Agent header is sent with each request', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(_nominatimJson(_sampleResults), 200);
      });

      final service = NominatimService(client: mockClient);
      await service.search('London');

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.headers['User-Agent'], isNotNull);
      expect(capturedRequest!.headers['User-Agent'], contains('postbox-game'));
    });

    test('request URL includes GB countrycodes and limit=5', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('[]', 200);
      });

      final service = NominatimService(client: mockClient);
      await service.search('Oxford');

      expect(capturedRequest, isNotNull);
      final uri = capturedRequest!.url;
      expect(uri.queryParameters['countrycodes'], 'gb');
      expect(uri.queryParameters['limit'], '5');
      expect(uri.queryParameters['format'], 'json');
    });

    test('throttle: two rapid calls are separated by at least 1 second',
        () async {
      int callCount = 0;
      final callTimes = <DateTime>[];

      final mockClient = MockClient((_) async {
        callCount++;
        callTimes.add(DateTime.now());
        return http.Response('[]', 200);
      });

      final service = NominatimService(client: mockClient);

      // Fire both calls without awaiting the first so they are "rapid".
      final f1 = service.search('London');
      final f2 = service.search('Manchester');

      await f1;
      await f2;

      expect(callCount, 2);
      final gap = callTimes[1].difference(callTimes[0]);
      expect(gap.inMilliseconds, greaterThanOrEqualTo(900),
          reason:
              'Second call should be delayed by ≥1 s due to throttle (gap was '
              '${gap.inMilliseconds} ms)');
    });

    test('throttle: three rapid calls each separated by ≥1 second', () async {
      // Regression test for a race the two-call test missed: with the old
      // throttle (update _lastCallAt only after the await), a third call
      // entering during the second call's wait would see the same
      // _lastCallAt as the second and queue against the same anchor —
      // collapsing onto the same wall-clock slot as the second call rather
      // than waiting another 1 s. Reserving the slot before the await
      // guarantees N>2 concurrent calls fan out 1 s apart.
      final callTimes = <DateTime>[];

      final mockClient = MockClient((_) async {
        callTimes.add(DateTime.now());
        return http.Response('[]', 200);
      });

      final service = NominatimService(client: mockClient);

      // Fire all three concurrently — no awaits between them.
      final futures = <Future<void>>[
        service.search('London'),
        service.search('Manchester'),
        service.search('Birmingham'),
      ];
      await Future.wait(futures);

      expect(callTimes.length, 3);
      final gap12 = callTimes[1].difference(callTimes[0]).inMilliseconds;
      final gap23 = callTimes[2].difference(callTimes[1]).inMilliseconds;
      expect(gap12, greaterThanOrEqualTo(900),
          reason: 'Call 1→2 gap was $gap12 ms, expected ≥1 s');
      expect(gap23, greaterThanOrEqualTo(900),
          reason: 'Call 2→3 gap was $gap23 ms, expected ≥1 s');
    });
  });
}
