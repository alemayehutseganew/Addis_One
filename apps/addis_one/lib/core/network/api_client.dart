import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../storage/token_storage.dart';
import 'api_failure.dart';

/// HTTP client for the Addis One API.
///
/// One client for the whole app, carrying the union of what the two separate
/// clients did. Two responsibilities beyond "send requests":
///
///  1. **Attach the bearer token** to every authenticated call, reading it from
///     the role-scoped [TokenStorage] this instance was built with.
///  2. **Map transport failures onto [ApiFailure]** so the UI can branch on the
///     cause. A raw DioException leaking into a widget means every screen
///     re-implements "what does a 503 mean", and they get it differently.
///
/// ## Why refresh is a constructor flag rather than a client difference
///
/// The passenger client refreshed a 401 once and retried silently; the staff
/// client deliberately did not. That difference was load-bearing: a passenger
/// losing their session mid-purchase loses nothing, whereas a field inspector
/// whose token expires mid-shift must be told, because a scan silently retried
/// against a stale session could be recorded against the wrong officer.
///
/// Two clients in one binary would have meant two [Dio] instances with subtly
/// different interceptors --?" the exact "two clients disagreeing about what a 403
/// means" divergence the staff client was written to avoid. So there is one
/// client and [refreshOnUnauthorized] carries the policy, supplied per role by
/// the composition root. The policy is still visible and testable; it is just
/// stated once, in one place, instead of being implied by which class you got.
class ApiClient {
  ApiClient({
    required TokenStorage tokens,
    Dio? dio,
    String baseUrl = AppConfig.apiBaseUrl,
    this.refreshOnUnauthorized = false,
    // The field is private but the parameter is not, deliberately: callers name
    // a dependency, not an implementation detail. An initializing formal would
    // force the private name into every call site.
    // ignore: prefer_initializing_formals
  })  : _tokens = tokens,
        _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = AppConfig.requestTimeout
      ..receiveTimeout = AppConfig.requestTimeout
      ..sendTimeout = AppConfig.requestTimeout
      ..headers = {'Content-Type': 'application/json'}
      // Only 2xx counts as success, so every 4xx reaches the error path below
      // and becomes an ApiException.
      //
      // This used to be `status < 500`, with a comment claiming that was what let
      // non-2xx reach `_toApiException`. It is the opposite: under `status < 500`
      // a 4xx is handed to the *success* path, `_toApiException` never runs for
      // it, and the caller receives an empty map. The consequences were not
      // cosmetic --?" a rate-limited 429 and a rejected 401 both arrived as "empty
      // body" and were reported as a wrong code, quietly burning the passenger's
      // remaining OTP attempts; and a 409 FARE_MISMATCH on `/payments` parsed as a
      // *successful* purchase. In the staff half the same bug signed an inspector
      // in with no role after their token expired.
      //
      // This predicate is the switch that decides whether Dio hands a response to
      // the success path or the error path, so it is stated once here for both
      // halves of the app.
      ..validateStatus = (status) => status != null && status >= 200 && status < 300;

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _tokens.accessToken;
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          _log('--> ${options.method} ${options.path} '
              'auth=${token == null || token.isEmpty ? 'no' : 'yes'}');
          handler.next(options);
        },
        onResponse: (response, handler) {
          // The status is logged because "the list is empty" and "the request
          // was rejected" look identical on screen, and this is the only place
          // that distinguishes them.
          _log('<-- ${response.statusCode} ${response.requestOptions.path}');
          handler.next(response);
        },
        onError: (err, handler) async {
          _log('<!! ${err.type.name} ${err.requestOptions.path} '
              'status=${err.response?.statusCode}');

          // Staff requests never take this branch: the policy below is gated on
          // [refreshOnUnauthorized], which the composition root only sets for the
          // passenger half.
          if (!refreshOnUnauthorized) return handler.next(err);

          final options = err.requestOptions;
// 401 retry. A 403 is deliberately excluded: it means the caller is
          // authenticated and still not permitted, so a fresh token cannot change
          // the answer and retrying would only spend a round trip.
          //
          // `retried` marks the request we are re-issuing, and `skipAuthRetry` is
          // set by the refresh call itself. Both are per-request on
          // `options.extra`, which is what makes this safe: a *second* 401 means
          // the new token is being refused too, and a refresh must never recurse
          // into its own retry.
          final alreadyRetried = options.extra[retriedFlag] == true;
          final isRefreshCall = options.extra[skipAuthRetryFlag] == true;

          if (err.response?.statusCode == 401 &&
              !alreadyRetried &&
              !isRefreshCall &&
              await _refreshOnce()) {
            options.extra[retriedFlag] = true;
            try {
              // Re-fetched rather than retried in place so the request interceptor
              // runs again and picks up the rotated access token.
              final fresh = await _dio.fetch<dynamic>(options);
              return handler.resolve(fresh);
            } on DioException catch (second) {
              // The retry failed too; report the original 401, which is the error
              // the caller can actually act on.
              _log('<!! retry also failed ${second.response?.statusCode} '
                  '${options.path}');
              return handler.next(err);
            }
          }

          handler.next(err);
        },
      ),
    );
  }

  /// Marks a request as exempt from the 401 refresh-and-retry.
  ///
  /// Set by the refresh call itself. Without it, a rejected refresh token would
  /// trigger another refresh, which would reject again, forever.
  static const String skipAuthRetryFlag = 'addis.skipAuthRetry';

  /// Marks a request that has already been retried once behind a new token.
  static const String retriedFlag = 'addis.retried';

  /// Whether a 401 should be refreshed once and the request re-issued.
  ///
  /// True for the passenger half, false for the staff half. See the class
  /// comment for why the two halves must differ.
  final bool refreshOnUnauthorized;

  /// Re-authenticates after a 401 and returns true if the request should retry.
  ///
  /// Wired in the composition root to `refreshSessionQuietly`. Left unset, a 401
  /// simply surfaces as [ApiFailure.unauthorized] --?" which is the correct staff
  /// behaviour and the correct fallback everywhere else.
  Future<bool> Function()? onUnauthorized;

  /// The refresh currently running, if any.
  ///
  /// The backend *rotates* the refresh token --?" every `/auth/refresh` spends the
  /// one it was given and returns a new pair. So if four requests each noticed
  /// the expired access token independently and each refreshed, four rotations
  /// would race on the same token and all but one would be rejected. Collapsing
  /// concurrent 401s onto one round trip is therefore correctness, not an
  /// optimisation.
  Future<bool>? _refreshInFlight;

  Future<bool> _refreshOnce() {
    return _refreshInFlight ??= _runRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<bool> _runRefresh() async {
    final hook = onUnauthorized;
    // No hook wired means this client cannot re-authenticate; the caller gets
    // the 401 and deals with it.
    if (hook == null) return false;
    try {
      return await hook();
    } catch (_) {
      // A refresh that throws is a failure to re-authenticate, not a crash.
      return false;
    }
  }

  /// Mirrors request/response pairs to logcat.
  ///
  /// A release build has no attached console, so a failed request is otherwise
  /// invisible. Bodies are NOT logged: they carry phone numbers, session tokens,
  /// and ticket credentials.
  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[ADDIS-HTTP] $message');
    }
  }

  final Dio _dio;
  final TokenStorage _tokens;

  Dio get raw => _dio;
Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
    Options? options,
  }) async {
    return _guard(() async {
      final res =
          await _dio.get<dynamic>(path, queryParameters: query, options: options);
      return _asMap(res.data);
    });
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Options? options,
  }) async {
    return _guard(() async {
      final res = await _dio.post<dynamic>(path, data: body, options: options);
      return _asMap(res.data);
    });
  }

  /// Replaces a resource.
  ///
  /// Used by the administration screens, which toggle things like a stop's
  /// active flag rather than editing them. Same envelope contract as [postJson]: a
  /// bare list or scalar is not a valid answer and is reported as an empty map,
  /// which is then visible to the caller as missing fields rather than as a
  /// silently wrong value.
  Future<Map<String, dynamic>> putJson(
    String path, {
    Object? body,
  }) async {
    return _guard(() async {
      final res = await _dio.put<dynamic>(path, data: body);
      return _asMap(res.data);
    });
  }

  /// Partially updates a resource.
  ///
  /// The admin routes take partial updates, so this is a distinct verb from
  /// [putJson] rather than a synonym: sending a PATCH where the server expects a
  /// PUT would silently change whether omitted fields are preserved or cleared.
  Future<Map<String, dynamic>> patchJson(
    String path, {
    Object? body,
  }) async {
    return _guard(() async {
      final res = await _dio.patch<dynamic>(path, data: body);
      return _asMap(res.data);
    });
  }

  /// Reads a route that answers with a bare JSON array.
  ///
  /// Necessary because this API is not uniform. `/driver/trips` answers
  /// `{ date, trips }` and `/validation/mine` answers `{ validations }`, but
  /// `GET /admin/stops`, `/admin/routes`, `/admin/vehicles`, `/admin/fare-rules`,
  /// `/admin/staff`, `/admin/operators`, `/staff/devices` and
  /// `/staff/shifts/variances` all answer with a plain array.
  ///
  /// Those are not conveniences to be tidied into envelopes here --?" they are what
  /// the server sends, and changing them would mean touching the reporting and
  /// administration surfaces for every other client. So the client adapts.
  ///
  /// Anything that is not a list comes back empty. That is the safe direction: a
  /// screen then shows "nothing recorded" rather than rendering a string as if it
  /// were a row.
  Future<List<dynamic>> getListJson(
    String path, {
    Map<String, String>? query,
  }) async {
    return _guard(() async {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      final data = res.data;
      return data is List ? data : const [];
    });
  }

  /// Runs [action], converting transport and status failures into
  /// [ApiException] with a meaningful [ApiFailure].
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  ApiException _toApiException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const ApiException(
          ApiFailure.network,
          message: 'The request timed out',
        );

      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return const ApiException(
          ApiFailure.network,
          message: 'Could not reach the server',
        );

      case DioExceptionType.cancel:
        return const ApiException(ApiFailure.cancelled);

      case DioExceptionType.badCertificate:
        return const ApiException(
          ApiFailure.network,
          message: 'The server certificate could not be verified',
        );

      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        final body = e.response?.data;
        final message = body is Map
            ? (body['message'] ?? body['error'])?.toString()
            : null;
        return ApiException(
          _statusToFailure(status),
          message: message,
          statusCode: status,
        );
    }
  }

  static ApiFailure _statusToFailure(int status) {
    if (status == 401) return ApiFailure.unauthorized;
    // 403 means the caller is authenticated and still not permitted. Reported as
    // unauthorized rather than a generic server fault, because the correct
    // response is "sign in as someone who can" --?" not "try again".
    if (status == 403) return ApiFailure.unauthorized;
    if (status == 404) return ApiFailure.notFound;
    if (status == 409 || status == 422) return ApiFailure.validation;
    return ApiFailure.server;
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    // A bare list or scalar is not a valid envelope for our endpoints.
    return const <String, dynamic>{};
  }
}