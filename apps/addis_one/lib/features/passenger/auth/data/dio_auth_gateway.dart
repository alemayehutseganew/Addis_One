import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/storage/token_storage.dart';
import '../../journey_planner/domain/transport_repository.dart';
import '../domain/auth_controller.dart';

/// Exchanges the stored refresh token for a fresh pair.
///
/// Returns true only when a new access token is actually in place, which is what
/// tells [ApiClient] the failed request is worth re-issuing. Every failure —
/// no refresh token stored, a rejected one, an unreachable server — answers
/// false, so the passenger sees the original 401 rather than a silent no-op.
///
/// Not a method on [AuthGateway] because that interface describes what a signed-
/// out user can do; this is the transparent path an already-signed-in user never
/// sees, and adding it there would put a method on every fake for no gain.
Future<bool> refreshSessionQuietly(ApiClient api, TokenStorage tokens) async {
  final refreshToken = await tokens.refreshToken;
  if (refreshToken == null || refreshToken.isEmpty) return false;

  try {
    final json = await api.postJson(
      '/auth/refresh',
      body: {'refreshToken': refreshToken},
      // Without this the refresh request would, on its own 401, trigger another
      // refresh — which would reject again, and again.
      options: Options(extra: {ApiClient.skipAuthRetryFlag: true}),
    );

    final accessToken = json['accessToken'];
    if (accessToken is! String || accessToken.isEmpty) return false;

    // A null refreshToken here keeps the stored one: `save` only writes the key
    // when given a value, which is the right behaviour for a server that issues
    // a bare access token instead of rotating the pair.
    await tokens.save(
      accessToken: accessToken,
      refreshToken: json['refreshToken'] as String?,
    );
    return true;
  } on ApiException {
    // The refresh token is spent, revoked, or the server is down. All three
    // mean the same thing to the caller: we could not re-authenticate.
    return false;
  }
}

/// Auth over the real API.
///
/// Maps HTTP failures onto [AuthErrorKind] so the UI distinguishes "wrong code"
/// from "rate limited" — showing the wrong message there would either leak
/// information or waste the user's remaining attempts.
class DioAuthGateway implements AuthGateway {
  DioAuthGateway(this._api, this._tokens);

  final ApiClient _api;
  final TokenStorage _tokens;

  @override
  Future<bool> requestOtp(String phoneE164) async {
    try {
      await _api.postJson('/auth/request-otp', body: {'phone': phoneE164});
      return true;
    } on ApiException catch (e) {
      throw _toGatewayError(e);
    }
  }

  @override
  Future<AuthSession> verifyOtp(String phoneE164, String code) async {
    try {
      final json = await _api.postJson('/auth/verify-otp', body: {
        'phone': phoneE164,
        'code': code,
      });

      // The backend returns {ok:false, error:'invalid_or_expired'} with HTTP 200
      // rather than a 401, so the refusal must be read from the body. Treating
      // that as success would sign the user in with no session at all.
      if (json['ok'] != true || json['accessToken'] == null) {
        throw const AuthGatewayException(AuthErrorKind.invalidCode);
      }

      final session = AuthSession(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String?,
        phoneE164: phoneE164,
        displayName: json['displayName'] as String?,
      );

      // Persist immediately: the access token is short-lived, so a user who
      // backgrounds the app must still be authenticated when they return.
      await _tokens.save(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        phone: phoneE164,
      );

      return session;
    } on ApiException catch (e) {
      throw _toGatewayError(e);
    }
  }

  /// Clears the stored session.
  @override
  Future<void> signOut() => _tokens.clearAll();

  @override
  Future<bool> devSignInAvailable() async {
    try {
      final json = await _api.getJson('/auth/dev-login');
      return json['enabled'] == true;
    } on ApiException {
      // 404 is the documented "route not registered" answer, and any other
      // failure means the same thing from this screen's point of view: the
      // shortcut is not something to offer.
      return false;
    }
  }

  @override
  Future<AuthSession> devSignIn(String phoneE164) async {
    try {
      final json = await _api.postJson('/auth/dev-login', body: {'phone': phoneE164});

      // The route is unregistered on any deployment without the flag, answering
      // 404. That is "not available here", not a failure worth showing, so it
      // becomes the same refusal the staff app reports.
      if (json['ok'] != true || json['accessToken'] is! String) {
        throw const AuthGatewayException(
          AuthErrorKind.unknown,
          'Sign-in shortcut is not available on this server',
        );
      }

      final session = AuthSession(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String?,
        phoneE164: phoneE164,
        displayName: json['displayName'] as String?,
      );
      await _tokens.save(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        phone: phoneE164,
      );
      return session;
    } on ApiException catch (e) {
      throw _toGatewayError(e);
    }
  }

  /// Temporary fixed-credential login (until SMS approved).
  ///
  /// The server answers 401 for bad credentials and 404 when the route is
  /// not armed. Both map through _toGatewayError: 404 becomes "unknown" with
  /// the server's message, which the screen shows only if the form was
  /// offered — and the form is offered only after the capability probe, so a
  /// 404 here means the flag was turned off mid-session, not a bug.
  @override
  Future<bool> passwordLoginAvailable() async {
    try {
      final json = await _api.getJson('/auth/password-login');
      return json['enabled'] == true;
    } on ApiException {
      return false;
    }
  }

  @override
  Future<AuthSession> passwordLogin(String username, String password) async {
    try {
      final json = await _api.postJson('/auth/password-login', body: {
        'username': username,
        'password': password,
      });

      if (json['ok'] != true || json['accessToken'] is! String) {
        throw const AuthGatewayException(
          AuthErrorKind.invalidCode,
          'Invalid username or password',
        );
      }

      final phone = json['phone'] as String? ?? '';
      final session = AuthSession(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String?,
        phoneE164: phone,
        displayName: json['displayName'] as String?,
      );
      await _tokens.save(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        phone: phone.isEmpty ? null : phone,
      );
      return session;
    } on ApiException catch (e) {
      // A 401 here is "wrong username/password", not "wrong OTP code" — but
      // AuthErrorKind has no password case, and invalidCode already renders
      // the right message ("Incorrect code…" is remapped below by the
      // controller? No: _mapError turns invalidCode into "Incorrect code").
      // So translate explicitly instead of reusing _toGatewayError.
      if (e.failure == ApiFailure.unauthorized) {
        throw const AuthGatewayException(
          AuthErrorKind.unknown,
          'Invalid username or password',
        );
      }
      throw _toGatewayError(e);
    }
  }

  static AuthGatewayException _toGatewayError(ApiException e) {
    switch (e.failure) {
      case ApiFailure.validation:
        final message = e.message?.toLowerCase() ?? '';
        if (message.contains('expired')) {
          return const AuthGatewayException(AuthErrorKind.tooManyAttempts);
        }
        return const AuthGatewayException(AuthErrorKind.invalidCode);

      case ApiFailure.unauthorized:
        return const AuthGatewayException(AuthErrorKind.invalidCode);

      case ApiFailure.network:
        return const AuthGatewayException(AuthErrorKind.network);

      case ApiFailure.server:
      case ApiFailure.notFound:
      case ApiFailure.timeout:
      case ApiFailure.offline:
      case ApiFailure.cancelled:
      case ApiFailure.unknown:
        return AuthGatewayException(AuthErrorKind.unknown, e.message);
    }
  }
}

