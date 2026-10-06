// Regression tests for the stop-picker's browse path.
//
// The picker opens with no query typed. The server treats a blank `q` as a
// browse and answers with a default page of stops, but the repository used to
// short-circuit a blank query to an empty list without making the call at all.
// On a handset that rendered as "No stops found" against a server holding 15
// stops, with nothing in the API log to explain it — the request never left the
// phone. These tests pin the contract on both repositories so the two cannot
// drift apart again.
//
// A real loopback HttpServer stands in for the API rather than a mocked Dio
// adapter: the point of the regression is *which query reached the wire*, and
// an adapter that answers whatever it likes cannot show that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:addis_one/core/auth/app_role.dart';
import 'package:addis_one/core/models/journey_plan.dart';
import 'package:addis_one/core/network/api_client.dart';
import 'package:addis_one/core/storage/token_storage.dart';
import 'package:addis_one/features/passenger/journey_planner/data/demo_transport_repository.dart';
import 'package:addis_one/features/passenger/journey_planner/data/http_transport_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// The stops a real `GET /stops` returns, encoded rather than hand-written so
/// the fixture cannot be the thing that is malformed.
final String _twoStopsBody = jsonEncode({
  'stops': [
    {
      'id': 'a',
      'code': 'ARD',
      'name': 'Arada',
      'nameAm': 'አራዳ',
      'latitude': 9.029,
      'longitude': 38.7493,
      'zone': 'Z1',
      'kind': 'stop',
    },
    {
      'id': 'b',
      'code': 'BOR',
      'name': 'Bole',
      'nameAm': 'ቦሌ',
      'latitude': 9.0144,
      'longitude': 38.7969,
      'zone': 'Z3',
      'kind': 'stop',
    },
  ],
});

void main() {
  // Secure storage is a platform channel and ApiClient reads a token on every
  // request; mocked empty so the interceptor resolves without a device.
  setUpAll(() => FlutterSecureStorage.setMockInitialValues({}));

  late HttpServer server;
  late String baseUrl;

  /// Every query string the repository actually put on the wire.
  late List<Map<String, String>> received;

  setUp(() async {
    received = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/api/v1';
    unawaited(server.forEach((HttpRequest request) async {
      received.add(request.uri.queryParameters);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(_twoStopsBody);
      await request.response.close();
    }));
  });

  tearDown(() async => server.close(force: true));

  HttpTransportRepository liveRepository() => HttpTransportRepository(
        api: ApiClient(
          tokens: TokenStorage(role: AppRole.passenger),
          dio: Dio(),
          baseUrl: baseUrl,
        ),
      );

  group('HttpTransportRepository.searchPlaces', () {
    test('a blank query still reaches the server, as a browse', () async {
      final stops = await liveRepository().searchPlaces('');

      // The regression: no request meant an empty picker with an empty log.
      expect(received, hasLength(1));
      // A browse omits `q` entirely rather than sending q=, so the server takes
      // its documented "no filter" branch and answers with a default page.
      expect(received.single.containsKey('q'), isFalse);
      expect(stops.map((p) => p.name), ['Arada', 'Bole']);
    });

    test('a whitespace-only query is a browse too', () async {
      await liveRepository().searchPlaces('   ');

      expect(received, hasLength(1));
      expect(received.single.containsKey('q'), isFalse);
    });

    test('a real query is passed through, trimmed', () async {
      final stops = await liveRepository().searchPlaces('  bole ');

      expect(received.single['q'], 'bole');
      expect(stops, hasLength(2));
    });
  });

  group('DemoTransportRepository.searchPlaces', () {
    // The demo build must behave like the live one, or the picker appears to
    // work in demos and breaks against the real server.
    test('a blank query browses instead of returning nothing', () async {
      final stops = await DemoTransportRepository().searchPlaces('');

      expect(stops, isNotEmpty);
    });

    test('a query still filters', () async {
      final stops = await DemoTransportRepository().searchPlaces('bole');

      expect(stops.map((p) => p.name), ['Bole']);
    });
  });

  group('Place mapping', () {
    test('a stop row survives the trip through JSON', () {
      // Guards the browse path specifically: these are the rows that used to
      // never be requested at all.
      final place = JourneyPlan.placeFromJson(<String, dynamic>{
        'id': 'a',
        'code': 'ARD',
        'name': 'Arada',
        'nameAm': 'አራዳ',
        'latitude': 9.029,
        'longitude': 38.7493,
        'zone': 'Z1',
        'kind': 'stop',
      });

      expect(place.name, 'Arada');
      expect(place.code, 'ARD');
      expect(place.latitude, 9.029);
    });
  });
}