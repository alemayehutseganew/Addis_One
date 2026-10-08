import '../../../../core/config/app_config.dart';
import '../domain/auth_state.dart';

/// What the auth flow needs from the outside world.
///
/// An interface so the sign-in rules — validation, attempt counting, state
/// transitions — are testable without an SMS gateway or a running server.
abstract interface class AuthGateway {
  /// Requests an OTP. Returns true when the SMS was accepted for delivery.
  Future<bool> requestOtp(String phoneE164);

  /// Verifies the code. Throws [AuthGatewayException] with a reason on failure.
  Future<AuthSession> verifyOtp(String phoneE164, String code);

  /// Clears the stored session.
  ///
  /// Part of the interface rather than a concrete-only method so the controller
  /// can sign out against a fake, and so a screen can never reach past the
  /// controller and wipe tokens without also resetting the UI state.
  Future<void> signOut();

  /// Whether the server currently offers the OTP bypass.
  ///
  /// Probes the side-effect-free capability endpoint rather than attempting a
  /// real sign-in: the sign-in route answers 404 both when it is unregistered
  /// *and* when a number is not provisioned, so the client cannot tell those two
  /// apart. This answers the capability question directly and issues nothing.
  Future<bool> devSignInAvailable() async => false;

  /// Whether the temporary fixed-credential test login is armed.
  ///
  /// Probes GET /auth/password-login, which 404s unless TEST_LOGIN_ENABLED
  /// is on. Allowed to fail closed: a screen that cannot ask simply does not
  /// show the username/password form.
  Future<bool> passwordLoginAvailable() async => false;

  /// Signs in with the fixed test username + password.
  Future<AuthSession> passwordLogin(String username, String password) async {
    throw const AuthGatewayException(
      AuthErrorKind.unknown,
      'Test sign-in is not available',
    );
  }

  /// Signs in without an OTP. Development only.
  ///
  /// Given a concrete default rather than being abstract so the fakes in
  /// `auth_controller_test.dart` do not all need implementing for a control they
  /// do not exercise. A gateway that has not opted in reports it as unavailable
  /// rather than failing with an unimplemented error.
  Future<AuthSession> devSignIn(String phoneE164) async {
    throw const AuthGatewayException(
      AuthErrorKind.unknown,
      'Sign-in shortcut is not available',
    );
  }
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.phoneE164,
    this.refreshToken,
    this.displayName,
  });

  final String accessToken;
  final String? refreshToken;
  final String phoneE164;
  final String? displayName;
}

enum AuthErrorKind {
  invalidCode,
  tooManyAttempts,
  rateLimited,
  network,
  unknown,
}

class AuthGatewayException implements Exception {
  const AuthGatewayException(this.kind, [this.message]);

  final AuthErrorKind kind;
  final String? message;

  @override
  String toString() => 'AuthGatewayException($kind, $message)';
}

/// Drives phone -> OTP -> session.
///
/// Security-relevant behaviour lives here rather than in widgets:
///
///  * The OTP is never logged or persisted.
///  * Attempts are counted and enforced locally as well as server-side, so a
///    modified client cannot burn the allowance on brute-force requests.
///  * The code expires on [otpTtl]; a late-arriving SMS is rejected rather
///    than accepted against a stale challenge.
class PassengerAuthController {
  PassengerAuthController({
    required AuthGateway gateway,
    DateTime Function()? clock,
    this.otpTtl = AppConfig.otpTtl,
    // Private field, public parameter: callers depend on the abstraction, not
    // on the field name. See ApiClient for the same pattern.
    // ignore: prefer_initializing_formals
  })  : _gateway = gateway,
        _now = clock ?? DateTime.now;

  final AuthGateway _gateway;
  final DateTime Function() _now;
  final Duration otpTtl;

  PassengerAuthState _state = const PassengerAuthUnknown();
  PassengerAuthState get state => _state;

  int _attempts = 0;
  DateTime? _sentAt;

  int get attemptsUsed => _attempts;

  /// Validates a phone number and moves to the OTP step.
  ///
  /// Returns false (and stays put) when the number is not a valid Ethiopian
  /// mobile — no request is sent in that case.
  Future<bool> submitPhone(String rawPhone) async {
    final normalized = EthiopianPhone.normalize(rawPhone);
    if (normalized == null) {
      _emit(const PassengerAuthFailure(
        'Enter a valid Ethiopian mobile number',
        canRetry: true,
      ));
      return false;
    }
    _emit(PassengerAuthPhoneEntered(normalized));
    return true;
  }

  /// Requests an OTP. Resends when [isResend].
  Future<bool> requestOtp({bool isResend = false}) async {
    final phone = _currentPhone;
    if (phone == null) return false;

    // A resend is not a fresh chance at guessing: the allowance persists.
    if (!OtpValidator.canAttempt(attemptsUsed: _attempts)) {
      _emit(const PassengerAuthFailure(
        'Too many incorrect codes. Request a new code.',
        canRetry: true,
      ));
      return false;
    }

    _emit(PassengerAuthOtpSent(
      phoneE164: phone,
      attemptsUsed: _attempts,
      isResending: isResend,
    ));

    try {
      final sent = await _gateway.requestOtp(phone);
      if (!sent) {
        _emit(const PassengerAuthFailure(
          'Could not send a code. Check the number and try again.',
        ));
        return false;
      }
      _sentAt = _now();
      _emit(PassengerAuthOtpSent(phoneE164: phone, attemptsUsed: _attempts));
      return true;
    } on AuthGatewayException catch (e) {
      _emit(_mapError(e));
      return false;
    }
  }

  /// Verifies the submitted code.
  Future<AuthSession?> submitCode(String rawCode) async {
    final phone = _currentPhone;
    if (phone == null) return null;

    final code = rawCode.trim();
    if (!OtpValidator.isWellFormed(code)) {
      _emit(PassengerAuthFailure('Enter the ${AppConfig.otpLength}-digit code'));
      return null;
    }

    // Expiry is checked against the local clock so a stale SMS cannot be used.
    final sentAt = _sentAt;
    if (sentAt != null && _now().difference(sentAt) > otpTtl) {
      _emit(const PassengerAuthFailure('That code has expired. Request a new one.'));
      return null;
    }

    if (!OtpValidator.canAttempt(attemptsUsed: _attempts)) {
      _emit(const PassengerAuthFailure('Too many attempts. Request a new code.'));
      return null;
    }

    _emit(PassengerAuthVerifying(phone, _attempts));

    try {
      final session = await _gateway.verifyOtp(phone, code);
      _attempts = 0;
      _sentAt = null;
      _emit(PassengerAuthAuthenticated(
        phoneE164: session.phoneE164,
        displayName: session.displayName,
      ));
      return session;
    } on AuthGatewayException catch (e) {
      if (e.kind == AuthErrorKind.invalidCode) {
        _attempts += 1;
      }
      final next = _mapError(e);
      // Stay on the OTP screen so the user can try again, but surface the
      // attempts remaining rather than failing into a dead end.
      if (e.kind == AuthErrorKind.invalidCode &&
          OtpValidator.canAttempt(attemptsUsed: _attempts)) {
        _emit(PassengerAuthOtpSent(phoneE164: phone, attemptsUsed: _attempts));
      } else {
        _emit(next);
      }
      return null;
    }
  }

  /// Signs in without an OTP, where the server offers that route.
  ///
  /// [phoneE164] must be passed in rather than read from state. This mirrors the
  /// staff app's `devSignIn`, where the control used to read a number from state
  /// that was empty until "send code" was pressed — so the shortcut sent no
  /// number and failed against a server that was working perfectly.
  ///
  /// Does not touch the attempt counter or the OTP clock: a bypass that consumed
  /// an attempt would make the real flow harder to reach, not easier.
  Future<AuthSession?> devSignIn(String phoneE164) async {
    final normalized = EthiopianPhone.normalize(phoneE164);
    if (normalized == null) {
      _emit(const PassengerAuthFailure(
        'Enter a valid Ethiopian mobile number',
        canRetry: true,
      ));
      return null;
    }

    _emit(PassengerAuthVerifying(normalized, _attempts));
    try {
      final session = await _gateway.devSignIn(normalized);
      _attempts = 0;
      _sentAt = null;
      _emit(PassengerAuthAuthenticated(
        phoneE164: session.phoneE164,
        displayName: session.displayName,
      ));
      return session;
    } on AuthGatewayException catch (e) {
      _emit(_mapError(e));
      return null;
    }
  }

  /// Whether the shortcut should be offered at all.
  ///
  /// Cheap and safe to call speculatively: the probe issues nothing and is
  /// allowed to fail closed, because a screen that cannot ask simply does not
  /// show the control.
  Future<bool> devSignInAvailable() async {
    try {
      return await _gateway.devSignInAvailable();
    } on Object {
      return false;
    }
  }

  /// Signs in with the fixed test username + password (until SMS approved).
  ///
  /// Returns null and emits a failure on bad credentials, mirroring devSignIn.
  Future<AuthSession?> passwordLogin(String username, String password) async {
    if (username.trim().isEmpty || password.isEmpty) {
      _emit(const PassengerAuthFailure(
        'Enter the test username and password',
        canRetry: true,
      ));
      return null;
    }

    _emit(PassengerAuthVerifying(_currentPhone ?? '', _attempts));
    try {
      final session = await _gateway.passwordLogin(
        username.trim().toLowerCase(),
        password,
      );
      _attempts = 0;
      _sentAt = null;
      _emit(PassengerAuthAuthenticated(
        phoneE164: session.phoneE164,
        displayName: session.displayName,
      ));
      return session;
    } on AuthGatewayException catch (e) {
      _emit(_mapError(e));
      return null;
    }
  }

  /// Whether the username/password form should be offered at all.
  Future<bool> passwordLoginAvailable() async {
    try {
      return await _gateway.passwordLoginAvailable();
    } on Object {
      return false;
    }
  }

  /// Returns to the phone step, keeping the remembered number.
  /// Clears the session and returns to the signed-out state.
  ///
  /// Lives here rather than being called on the gateway from a screen: a widget
  /// that reaches past the controller can clear tokens without resetting the
  /// in-memory state, leaving the UI showing an account whose credentials are
  /// already gone. Both halves have to move together, so they move together.
  Future<void> signOut() async {
    await _gateway.signOut();
    // PassengerAuthUnknown, not an error: nobody signed in is the normal resting state
    // both before sign-in and after signing out.
    _emit(const PassengerAuthUnknown());
  }

  void backToPhone() {
    final phone = _currentPhone;
    _attempts = 0;
    _sentAt = null;
    _emit(phone == null ? const PassengerAuthUnknown() : PassengerAuthPhoneEntered(phone));
  }

  String? get _currentPhone => switch (_state) {
        PassengerAuthPhoneEntered(:final phoneE164) => phoneE164,
        PassengerAuthOtpSent(:final phoneE164) => phoneE164,
        PassengerAuthVerifying(:final phoneE164) => phoneE164,
        _ => null,
      };

  PassengerAuthFailure _mapError(AuthGatewayException e) {
    switch (e.kind) {
      case AuthErrorKind.invalidCode:
        final left = OtpValidator.remainingAttempts(_attempts + 1);
        return PassengerAuthFailure(
          left > 0 ? 'Incorrect code. $left attempts left.' : 'Incorrect code.',
          canRetry: left > 0,
        );
      case AuthErrorKind.tooManyAttempts:
        return const PassengerAuthFailure('Too many attempts. Request a new code.');
      case AuthErrorKind.rateLimited:
        return const PassengerAuthFailure('Too many requests. Try again shortly.');
      case AuthErrorKind.network:
        return const PassengerAuthFailure('Network problem. Check your connection.');
      case AuthErrorKind.unknown:
        return PassengerAuthFailure(e.message ?? 'Something went wrong.');
    }
  }

  void _emit(PassengerAuthState next) => _state = next;
}
