// Tests for the HTTP layer.
//
// This file exists because a whole category of bug was invisible to the rest of
// the suite: `ApiClient` decides, in one predicate, whether a response is a
// result or a failure, and every unit test elsewhere exercises the layers
// *above* it with hand-written return values. A misconfigured predicate
// therefore passed everything — and on a device it meant an inspector whose
// session had expired was told "Your role cannot scan" instead of being asked
// to sign in again.
//
// The adapter below answers with canned responses so the mapping from HTTP
// status to ApiFailure is tested directly, with no server involved.
import 'dart:convert';
import 'dart:typed_data';

import 'package:addis_one/core/network/api_client.dart';
import 'package:addis_one/core/network/api_failure.dart';
import 'package:addis_one/core/storage/token_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with one canned response.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({required this.status, required this.body});

  final int status;
  final Map<String, dynamic> body;

  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeTokens implements TokenStorage {
  _FakeTokens(this._accessToken);

  final String? _accessToken;

  @override
  Future<String?> get accessToken async => _accessToken;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ApiClient _clientFor(_StubAdapter adapter, {String? token = 'token-abc'}) {
  return ApiClient(
    tokens: _FakeTokens(token),
    dio: Dio()..httpClientAdapter = adapter,
    baseUrl: 'http://localhost:3000/api/v1',
  );
}

void main() {
  group('ApiClient status mapping', () {
    test('returns a 2xx body as a result', () async {
      final client = _clientFor(
        _StubAdapter(
          status: 200,
          body: {
            'staff': {'role': 'INSPECTOR', 'display': 'Selassie'},
            'permissions': {'canValidate': true},
          },
        ),
      );

      final data = await client.getJson('/auth/staff-session');

      expect(data['permissions']['canValidate'], isTrue);
    });

    test('passes a 200 through even when the body reports a failure', () async {
      // `/auth/verify-otp` answers 200 with `ok: false` for a wrong code. That is
      // a delivered answer, not a transport failure, and collapsing the two here
      // would make a mistyped OTP look like a server fault.
      final client = _clientFor(
        _StubAdapter(status: 200, body: {'ok': false, 'error': 'invalid'}),
      );

      final data = await client.postJson('/auth/verify-otp', body: {});

      expect(data['ok'], isFalse);
    });

    test('raises unauthorized for 401 rather than returning the body', () async {
      // The regression. A 401 used to be handed back as a normal result and
      // parsed into an empty session, signing the officer in with no role.
      final client = _clientFor(
        _StubAdapter(status: 401, body: {'message': 'Missing bearer token'}),
      );

      await expectLater(
        client.getJson('/auth/staff-session'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.failure, 'failure', ApiFailure.unauthorized)
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('raises unauthorized for 403, so a role refusal is not a server fault',
        () async {
      final client = _clientFor(
        _StubAdapter(status: 403, body: {'message': 'Staff access required'}),
      );

      await expectLater(
        client.postJson('/validation/scan', body: {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.failure, 'failure', ApiFailure.unauthorized),
        ),
      );
    });

    test('raises notFound for 404, which is how a disarmed route answers',
        () async {
      // DevLoginGuard 404s rather than 403s so the path cannot be probed. The
      // repository relies on being able to tell that apart from a real fault.
      final client = _clientFor(
        _StubAdapter(status: 404, body: {'message': 'Not Found'}),
      );

      await expectLater(
        client.getJson('/auth/dev-login'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.failure, 'failure', ApiFailure.notFound),
        ),
      );
    });

    test('raises validation for 409', () async {
      final client = _clientFor(_StubAdapter(status: 409, body: {}));
      await expectLater(
        client.postJson('/validation/scan', body: {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.failure, 'failure', ApiFailure.validation),
        ),
      );
    });

    test('raises server for 500', () async {
      final client = _clientFor(_StubAdapter(status: 500, body: {}));
      await expectLater(
        client.getJson('/auth/staff-session'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.failure, 'failure', ApiFailure.server),
        ),
      );
    });

    test('surfaces the server message rather than a generic string', () async {
      final client = _clientFor(
        _StubAdapter(status: 403, body: {'message': 'Insufficient role'}),
      );

      await expectLater(
        client.postJson('/validation/scan', body: {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'Insufficient role'),
        ),
      );
    });
  });

  group('ApiClient request headers', () {
    test('attaches the stored bearer token', () async {
      final adapter = _StubAdapter(status: 200, body: {});
      final client = _clientFor(adapter);

      await client.getJson('/auth/staff-session');

      expect(adapter.lastOptions!.headers['Authorization'], 'Bearer token-abc');
    });

    test('sends no Authorization header when nothing is stored', () async {
      final adapter = _StubAdapter(status: 200, body: {});
      final client = _clientFor(adapter, token: null);

      await client.getJson('/auth/staff-session');

      expect(
        adapter.lastOptions!.headers.containsKey('Authorization'),
        isFalse,
      );
    });
  });
}