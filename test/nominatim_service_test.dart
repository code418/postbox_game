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
  });
}
