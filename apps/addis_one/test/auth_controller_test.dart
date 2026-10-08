import 'package:addis_one/core/config/app_config.dart';
import 'package:addis_one/features/passenger/auth/domain/auth_controller.dart';
import 'package:addis_one/features/passenger/auth/domain/auth_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scriptable gateway so every branch of the sign-in flow can be driven
/// without an SMS provider or a server.
class FakeAuthGateway implements AuthGateway {
  FakeAuthGateway({
    this.requestSucceeds = true,
    this.acceptedCode = '123456',
    this.errorOnVerify,
    this.errorOnRequest,
    this.devEnabled = false,
    this.errorOnDevSignIn,
    this.passwordLoginEnabled = false,
    this.errorOnPasswordLogin,
  });

  bool requestSucceeds;
  String acceptedCode;
  AuthErrorKind? errorOnVerify;
  AuthErrorKind? errorOnRequest;

  /// Whether the server is pretending the bypass route exists.
  bool devEnabled;
  AuthErrorKind? errorOnDevSignIn;

  /// Whether the test username/password login is enabled.
  bool passwordLoginEnabled;
  AuthErrorKind? errorOnPasswordLogin;

  final List<String> requestedPhones = [];
  final List<List<String>> verifyCalls = [];
  final List<String> devSignInPhones = [];
  final List<String> passwordLoginCalls = [];
  int signOutCalls = 0;

  @override
  Future<bool> requestOtp(String phoneE164) async {
    requestedPhones.add(phoneE164);
    if (errorOnRequest != null) {
      throw AuthGatewayException(errorOnRequest!);
    }
    return requestSucceeds;
  }

  @override
  Future<AuthSession> verifyOtp(String phoneE164, String code) async {
    verifyCalls.add([phoneE164, code]);
    if (errorOnVerify != null) {
      throw AuthGatewayException(errorOnVerify!);
    }
    if (code != acceptedCode) {
      throw const AuthGatewayException(AuthErrorKind.invalidCode);
    }
    return AuthSession(
      accessToken: 'token-$phoneE164',
      refreshToken: 'refresh-1',
      phoneE164: phoneE164,
      displayName: 'Test User',
    );
  }

  @override
  Future<void> signOut() async => signOutCalls++;

  @override
  Future<bool> devSignInAvailable() async => devEnabled;

  @override
  Future<bool> passwordLoginAvailable() async => passwordLoginEnabled;

  @override
  Future<AuthSession> passwordLogin(String username, String password) async {
    passwordLoginCalls.add('$username:$password');
    if (!passwordLoginEnabled) {
      throw const AuthGatewayException(
        AuthErrorKind.unknown,
        'Test sign-in is not available',
      );
    }
    if (errorOnPasswordLogin != null) {
      throw AuthGatewayException(errorOnPasswordLogin!);
    }
    if (username != 'passenger' && username != 'staff') {
      throw const AuthGatewayException(AuthErrorKind.invalidCode);
    }
    if (password != 'test123') {
      throw const AuthGatewayException(AuthErrorKind.invalidCode);
    }
    return AuthSession(
      accessToken: 'test-token-$username',
      refreshToken: 'test-refresh',
      phoneE164: username == 'passenger' ? '+251900000001' : '+251900000002',
      displayName: username == 'passenger' ? 'Test Passenger' : 'Test Staff',
    );
  }

  @override
  Future<AuthSession> devSignIn(String phoneE164) async {
    devSignInPhones.add(phoneE164);
    if (errorOnDevSignIn != null) {
      throw AuthGatewayException(errorOnDevSignIn!);
    }
    if (!devEnabled) {
      throw const AuthGatewayException(AuthErrorKind.unknown);
    }
    return AuthSession(
      accessToken: 'dev-token-$phoneE164',
      refreshToken: 'dev-refresh',
      phoneE164: phoneE164,
      displayName: 'Dev User',
    );
  }
}

void main() {
  group('dev sign-in bypass', () {
    test('is not offered when the server does not arm the route', () async {
      final gateway = FakeAuthGateway(devEnabled: false);
      final controller = PassengerAuthController(gateway: gateway);
      expect(await controller.devSignInAvailable(), isFalse);
    });

    test('is offered once the server confirms it', () async {
      final gateway = FakeAuthGateway(devEnabled: true);
      final controller = PassengerAuthController(gateway: gateway);
      expect(await controller.devSignInAvailable(), isTrue);
    });

    test('signs in with the number it was given, not a stale one', () async {
      // Regression test. The staff app's shortcut once read the number from
      // state, which is empty until "send code" is pressed — so it sent nothing
      // and failed against a server that was working perfectly.
      final gateway = FakeAuthGateway(devEnabled: true);
      final controller = PassengerAuthController(gateway: gateway);

      final session = await controller.devSignIn('+251911223344');

      expect(session, isNotNull);
      expect(gateway.devSignInPhones, ['+251911223344']);
      expect(controller.state, isA<PassengerAuthAuthenticated>());
    });

    test('refuses a malformed number without calling the server', () async {
      final gateway = FakeAuthGateway(devEnabled: true);
      final controller = PassengerAuthController(gateway: gateway);

      expect(await controller.devSignIn('4'), isNull);
      expect(gateway.devSignInPhones, isEmpty);
      expect(
        (controller.state as PassengerAuthFailure).message,
        contains('valid Ethiopian mobile'),
      );
    });

    test('normalises the number the same way the OTP flow does', () async {
      // Otherwise the same account would be two different users depending on
      // which entry point was used.
      final gateway = FakeAuthGateway(devEnabled: true);
      final controller = PassengerAuthController(gateway: gateway);

      await controller.devSignIn('0911223344');

      expect(gateway.devSignInPhones, ['+251911223344']);
    });

    test('does not consume an OTP attempt', () async {
      // A bypass that burned an attempt would make the real flow harder to
      // reach, which is the opposite of what a test shortcut is for.
      final gateway = FakeAuthGateway(devEnabled: true);
      final controller = PassengerAuthController(gateway: gateway);

      await controller.devSignIn('+251911223344');

      expect(controller.attemptsUsed, 0);
    });

    test('surfaces a refusal rather than appearing to succeed', () async {
      final gateway = FakeAuthGateway(
        devEnabled: true,
        errorOnDevSignIn: AuthErrorKind.network,
      );
      final controller = PassengerAuthController(gateway: gateway);

      expect(await controller.devSignIn('+251911223344'), isNull);
      expect(controller.state, isA<PassengerAuthFailure>());
    });

    test('a probe that throws reports the shortcut as unavailable', () async {
      // Failing closed: a screen that cannot ask simply does not show the
      // control, rather than showing one that would fail on press.
      final controller = PassengerAuthController(
        gateway: _ThrowingProbeGateway(),
      );
      expect(await controller.devSignInAvailable(), isFalse);
    });
  });

  group('sign out', () {
    test('clears the stored session and returns to signed-out state', () async {
      final gateway = FakeAuthGateway();
      final controller = PassengerAuthController(gateway: gateway);

      await controller.submitPhone('0911234567');
      await controller.requestOtp();
      await controller.submitCode('123456');
      expect(controller.state, isA<PassengerAuthAuthenticated>());

      await controller.signOut();

      expect(gateway.signOutCalls, 1,
          reason: 'tokens must be cleared, not just the in-memory state');
      expect(controller.state, isA<PassengerAuthUnknown>(),
          reason: 'a signed-out user must not still look signed in');
    });
  });

  group('EthiopianPhone.normalize', () {
    test('accepts local 09 numbers', () {
      expect(EthiopianPhone.normalize('0911234567'), '+251911234567');
    });

    test('accepts +251 international form', () {
      expect(EthiopianPhone.normalize('+251911234567'), '+251911234567');
    });

    test('accepts 251 without a plus', () {
      expect(EthiopianPhone.normalize('251911234567'), '+251911234567');
    });

    test('tolerates spaces and dashes', () {
      expect(EthiopianPhone.normalize('+251 91 123 4567'), '+251911234567');
      expect(EthiopianPhone.normalize('091-123-4567'), '+251911234567');
    });

    test('accepts the Safaricom 7 prefix', () {
      expect(EthiopianPhone.normalize('0711234567'), '+251711234567');
    });

    test('rejects wrong length', () {
      expect(EthiopianPhone.normalize('091123456'), isNull);
      expect(EthiopianPhone.normalize('09112345678'), isNull);
    });

    test('rejects landline and non-mobile prefixes', () {
      expect(EthiopianPhone.normalize('0111234567'), isNull);
      expect(EthiopianPhone.normalize('0211234567'), isNull);
      expect(EthiopianPhone.normalize('0512345678'), isNull);
    });

    test('rejects garbage', () {
      expect(EthiopianPhone.normalize(''), isNull);
      expect(EthiopianPhone.normalize('abc'), isNull);
      expect(EthiopianPhone.normalize('+44 7911 123456'), isNull);
    });
  });

  group('EthiopianPhone presentation', () {
    test('pretty groups digits', () {
      expect(EthiopianPhone.pretty('+251911234567'), '+251 91 123 4567');
    });

    test('masked hides the middle', () {
      expect(EthiopianPhone.masked('+251911234567'), '+251•••••67');
    });

    test('does not throw on unexpected input', () {
      expect(EthiopianPhone.pretty('nonsense'), 'nonsense');
      expect(EthiopianPhone.masked('+25'), '+25');
    });
  });

  group('OtpValidator', () {
    test('requires exactly six digits', () {
      expect(OtpValidator.isWellFormed('123456'), isTrue);
      expect(OtpValidator.isWellFormed('12345'), isFalse);
      expect(OtpValidator.isWellFormed('1234567'), isFalse);
      expect(OtpValidator.isWellFormed('12345a'), isFalse);
      expect(OtpValidator.isWellFormed(' 123456 '), isTrue);
    });

    test('counts down remaining attempts and never goes negative', () {
      expect(OtpValidator.remainingAttempts(0), AppConfig.maxOtpAttempts);
      expect(OtpValidator.remainingAttempts(4), 1);
      expect(OtpValidator.remainingAttempts(5), 0);
      expect(OtpValidator.remainingAttempts(9), 0);
    });

    test('blocks further attempts once exhausted', () {
      expect(OtpValidator.canAttempt(attemptsUsed: 4), isTrue);
      expect(OtpValidator.canAttempt(attemptsUsed: 5), isFalse);
    });
  });

  group('PassengerAuthController — phone step', () {
    test('rejects an invalid number without calling the gateway', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      final ok = await c.submitPhone('123');

      expect(ok, isFalse);
      expect(c.state, isA<PassengerAuthFailure>());
      expect(gw.requestedPhones, isEmpty);
    });

    test('normalises and moves to the OTP step', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      final ok = await c.submitPhone('0911234567');

      expect(ok, isTrue);
      final state = c.state as PassengerAuthPhoneEntered;
      expect(state.phoneE164, '+251911234567');
    });
  });

  group('PassengerAuthController — OTP flow', () {
    test('reaches Authenticated on a correct code', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();
      final session = await c.submitCode('123456');

      expect(session, isNotNull);
      expect(session!.accessToken, 'token-+251911234567');
      expect(c.state, isA<PassengerAuthAuthenticated>());
    });

    test('stays on the OTP screen after a wrong code and counts it', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();
      final session = await c.submitCode('000000');

      expect(session, isNull);
      expect(c.state, isA<PassengerAuthOtpSent>());
      expect(c.attemptsUsed, 1);
      expect((c.state as PassengerAuthOtpSent).attemptsRemaining,
          AppConfig.maxOtpAttempts - 1);
    });

    test('locks out after the allowance is exhausted', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();

      for (var i = 0; i < AppConfig.maxOtpAttempts; i++) {
        await c.submitCode('000000');
      }

      // The next attempt is refused without calling the gateway at all.
      final before = gw.verifyCalls.length;
      final session = await c.submitCode('000000');
      expect(session, isNull);
      expect(gw.verifyCalls.length, before);
      expect(c.state, isA<PassengerAuthFailure>());
    });

    test('rejects a malformed code before calling the gateway', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();
      final session = await c.submitCode('12');

      expect(session, isNull);
      expect(gw.verifyCalls, isEmpty);
      expect(c.state, isA<PassengerAuthFailure>());
    });

    test('rejects an expired code without calling the gateway', () async {
      var now = DateTime(2026, 10, 1, 12);
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(
        gateway: gw,
        clock: () => now,
        otpTtl: const Duration(minutes: 5),
      );

      await c.submitPhone('0911234567');
      await c.requestOtp();

      // Jump past the TTL: the SMS may still arrive, but it must not be usable.
      now = now.add(const Duration(minutes: 6));
      final session = await c.submitCode('123456');

      expect(session, isNull);
      expect(gw.verifyCalls, isEmpty);
      expect(c.state, isA<PassengerAuthFailure>());
      expect((c.state as PassengerAuthFailure).message, contains('expired'));
    });

    test('a resend does not reset the attempt allowance', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();
      await c.submitCode('000000'); // 1 attempt used

      await c.requestOtp(isResend: true);

      expect(c.attemptsUsed, greaterThanOrEqualTo(1));
      expect(gw.requestedPhones.length, 2);
    });

    test('surfaces a network failure', () async {
      final gw = FakeAuthGateway(errorOnRequest: AuthErrorKind.network);
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      final ok = await c.requestOtp();

      expect(ok, isFalse);
      expect(c.state, isA<PassengerAuthFailure>());
      expect((c.state as PassengerAuthFailure).message, contains('Network'));
    });

    test('reports a failed send', () async {
      final gw = FakeAuthGateway(requestSucceeds: false);
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      final ok = await c.requestOtp();

      expect(ok, isFalse);
      expect(c.state, isA<PassengerAuthFailure>());
    });

    test('backToPhone keeps the number and clears attempts', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();
      await c.submitCode('000000');
      expect(c.attemptsUsed, 1);

      c.backToPhone();

      expect(c.state, isA<PassengerAuthPhoneEntered>());
      expect(c.attemptsUsed, 0);
    });

    test('a successful sign-in resets the counter', () async {
      final gw = FakeAuthGateway();
      final c = PassengerAuthController(gateway: gw);

      await c.submitPhone('0911234567');
      await c.requestOtp();
      await c.submitCode('000000');
      await c.submitCode('123456');

      expect(c.attemptsUsed, 0);
      expect(c.state, isA<PassengerAuthAuthenticated>());
    });
  });
}

/// A gateway whose capability probe fails, standing in for a server that is down.
///
/// Declared at the foot of the file so the test bodies read in order.
class _ThrowingProbeGateway extends FakeAuthGateway {
  @override
  Future<bool> devSignInAvailable() async =>
      throw const AuthGatewayException(AuthErrorKind.network);
}
