// Tests for the 401 refresh-and-retry path in ApiClient.
//
// The hook existed and was never wired: a 401 simply surfaced as an
// ApiException, so a passenger whose short-lived access token expired mid-session
// was dropped back to the sign-in screen holding a perfectly good refresh token.
//
// A real loopback HttpServer stands in for the API, as in stop_browse_test.dart.
// That is not ceremony here — the behaviours under test are all *about the wire*:
// that the retry really re-sent the request, that it carried the rotated token,
// and that concurrent 401s produced exactly one refresh. A mocked Dio adapter
// answers whatever it is told and could not show any of that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:addis_one/core/network/api_client.dart';
import 'package:addis_one/core/auth/app_role.dart';
import 'package:addis_one/core/storage/token_storage.dart';
import 'package:addis_one/features/passenger/auth/data/dio_auth_gateway.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:addis_one/core/network/api_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Secure storage is a platform channel; ApiClient reads a token on every
  // request and the refresh path reads the refresh token, so it is mocked.
  setUpAll(() => FlutterSecureStorage.setMockInitialValues({}));

  late HttpServer server;
  late String baseUrl;
  late List<String> paths;
  late List<String?> bearerSeen;

  /// Access token the server will accept. Rotated by each refresh.
  var validAccess = 'access-1';
  var refreshCalls = 0;
  var refreshShouldFail = false;
  var refreshShouldOmitAccess = false;

  setUp(() async {
    // `setMockInitialValues` is static, so the backing store survives between
    // tests. Without clearing it here, a refresh token seeded by one test is
    // still present in the next and a "no refresh token stored" case silently
    // inherits one.
    FlutterSecureStorage.setMockInitialValues({});
    paths = [];
    bearerSeen = [];
    validAccess = 'access-1';
    refreshCalls = 0;
    refreshShouldFail = false;
    refreshShouldOmitAccess = false;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/api/v1';
    unawaited(server.forEach((HttpRequest request) async {
      final path = request.uri.path;
      paths.add(path);
      final auth = request.headers.value('authorization');
      bearerSeen.add(auth == null || auth.isEmpty ? null : auth.split(' ').last);
      await request.drain<void>();

      if (path.endsWith('/auth/refresh')) {
        refreshCalls++;
        if (refreshShouldFail) {
          request.response.statusCode = HttpStatus.unauthorized;
          return request.response.close();
        }
        validAccess = 'access-${refreshCalls + 1}';
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'accessToken': refreshShouldOmitAccess ? null : validAccess,
          'refreshToken': 'refresh-rotated-$refreshCalls',
        }));
        return request.response.close();
      }

      // Answers 403 regardless of token, standing in for a citizen token
      // reaching a staff-only route.
      if (path.endsWith('/admin')) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'message': 'forbidden'}));
        return request.response.close();
      }

      if (auth != 'Bearer $validAccess') {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'message': 'token expired'}));
        return request.response.close();
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true, 'path': path}));
      await request.response.close();
    }));
  });

  tearDown(() async => server.close(force: true));

  ApiClient clientWithRefresh(TokenStorage tokens) {
    final api = ApiClient(
      tokens: tokens,
      baseUrl: baseUrl,
      refreshOnUnauthorized: true,
    );
    api.onUnauthorized = () => refreshSessionQuietly(api, tokens);
    return api;
  }

  /// A stale access token alongside a perfectly good refresh token.
  TokenStorage seededTokens() {
    FlutterSecureStorage.setMockInitialValues({
      'addis_one_passenger_access_token': 'stale-access',
      'addis_one_passenger_refresh_token': 'refresh-original',
    });
    return TokenStorage(role: AppRole.passenger, storage: FlutterSecureStorage());
  }
test('a 401 is refreshed and the request retried transparently', () async {
    final tokens = seededTokens();

    final result = await clientWithRefresh(tokens).getJson('/tickets/mine');

    // The caller got data, not an exception — this is the whole point.
    expect(result['ok'], isTrue);
    expect(paths.where((p) => p.endsWith('/auth/refresh')), hasLength(1));
    // The retry carried the rotated token, not the stale one.
    expect(bearerSeen.last, validAccess);
    expect(await tokens.accessToken, 'access-2');
  });

  test('the rotated refresh token is stored, not the spent one', () async {
    final tokens = seededTokens();
    await clientWithRefresh(tokens).getJson('/tickets/mine');

    // The server rotates. Keeping the old one would spend it a second time and
    // sign the passenger out on the *next* expiry, not this one.
    expect(await tokens.refreshToken, 'refresh-rotated-1');
  });

  test('concurrent 401s share one refresh', () async {
    final api = clientWithRefresh(seededTokens());

    final results = await Future.wait([
      api.getJson('/tickets/mine'),
      api.getJson('/journeys/plan'),
      api.getJson('/stops'),
    ]);

    // Three requests, three 401s — but the refresh token is single-use, so one
    // refresh per request would invalidate the others and leave the passenger
    // signed out through no fault of their own.
    expect(refreshCalls, 1);
    for (final r in results) {
      expect(r['ok'], isTrue, reason: 'every caller should recover');
    }
  });

  test('a rejected refresh surfaces the original 401', () async {
    refreshShouldFail = true;

    await expectLater(
      clientWithRefresh(seededTokens()).getJson('/tickets/mine'),
      throwsA(isA<ApiException>()
          .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
    );
  });

  test('a 403 does not attempt a refresh', () async {
    // 403 means authenticated but not permitted. A new token cannot change the
    // answer, so retrying would burn a round trip and spend a refresh token.
    final tokens = seededTokens();
    await tokens.save(accessToken: validAccess);

    await expectLater(
      clientWithRefresh(tokens).getJson('/admin'),
      throwsA(isA<ApiException>()
          .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
    );
    expect(refreshCalls, 0);
  });

  test('an expired session is retried only once', () async {
    // The server also rejects the rotated token, so the retry 401s too. That
    // must surface rather than loop.
    final tokens = seededTokens();
    final api = ApiClient(
      tokens: tokens,
      baseUrl: baseUrl,
      refreshOnUnauthorized: true,
    );
    var hookCalls = 0;
    api.onUnauthorized = () async {
      hookCalls++;
      // Persist a token the server will still refuse.
      await tokens.save(accessToken: 'still-wrong');
      return true;
    };

    await expectLater(
      api.getJson('/tickets/mine'),
      throwsA(isA<ApiException>()
          .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
    );
    expect(hookCalls, 1, reason: 'one attempt, not an unbounded loop');
  });

  test('no refresh token stored means no refresh call', () async {
    final storage = FlutterSecureStorage();
    await storage.write(key: 'addis_one_passenger_access_token', value: 'stale-access');
    final tokens = TokenStorage(role: AppRole.passenger, storage: storage);

    await expectLater(
      clientWithRefresh(tokens).getJson('/tickets/mine'),
      throwsA(isA<ApiException>()
          .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
    );
    expect(refreshCalls, 0);
  });

  test('a refresh without an access token is not treated as success', () async {
    refreshShouldOmitAccess = true;

    await expectLater(
      clientWithRefresh(seededTokens()).getJson('/tickets/mine'),
      throwsA(isA<ApiException>()
          .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
    );
    expect(refreshCalls, 1);
  });

  group('the staff half is NOT refreshed silently', () {
    // The two halves share one ApiClient class but not one policy. An officer
    // whose token expires mid-shift must be told, because a scan silently
    // retried against a stale session could be recorded against the wrong
    // officer.
    ApiClient clientWithoutRefresh(TokenStorage tokens) =>
        ApiClient(tokens: tokens, baseUrl: baseUrl);

    test('a 401 surfaces instead of being retried', () async {
      final tokens = seededTokens();

      await expectLater(
        clientWithoutRefresh(tokens).getJson('/validation/scan'),
        throwsA(isA<ApiException>()
            .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
      );

      // Nothing was refreshed, so the server never saw a second request.
      expect(refreshCalls, 0);
    });

    test('the stored credential is left untouched', () async {
      // A refresh rotates the token, so silently performing one would replace an
      // officer's credential with a fresh pair they never asked for.
      final tokens = seededTokens();

      await expectLater(
        clientWithoutRefresh(tokens).getJson('/validation/scan'),
        throwsA(isA<ApiException>()),
      );

      expect(await tokens.accessToken, 'stale-access');
      expect(await tokens.refreshToken, 'refresh-original');
    });
  });
}