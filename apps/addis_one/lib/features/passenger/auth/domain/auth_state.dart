import 'package:equatable/equatable.dart';

import '../../../../core/config/app_config.dart';

/// Ethiopian mobile number handling.
///
/// Ethiopia moved to a closed nine-digit plan: mobile numbers are 07XX/09XX
/// locally and +2517XX/9XX internationally. Validating this on the device
/// avoids a pointless SMS round-trip for a number that could never work, which
/// matters because OTP requests are rate limited.
class EthiopianPhone {
  const EthiopianPhone._();

  /// Accepts `0911234567`, `+251911234567`, `251911234567`, and tolerates
  /// spaces and dashes. Returns the canonical `+2519XXXXXXXX` form, or null if
  /// the number is not a valid Ethiopian mobile.
  static String? normalize(String input) {
    final digits = input.replaceAll(RegExp(r'[\s\-()]'), '');
    if (digits.isEmpty) return null;

    String local;
    if (digits.startsWith('+251')) {
      local = digits.substring(4);
    } else if (digits.startsWith('251')) {
      // 12 digits after the prefix: 9 national + 3 for "251". Reject anything
      // else rather than slicing blindly and producing a wrong-length number.
      if (digits.length != 12) return null;
      local = digits.substring(3);
    } else if (digits.startsWith('0')) {
      local = digits.substring(1);
    } else {
      local = digits;
    }

    // Nine digits, and the mobile prefixes are 7 (Safaricom) and 9 (Ethio Telecom).
    if (local.length != 9) return null;
    if (!RegExp(r'^[79]\d{8}$').hasMatch(local)) return null;

    return '+251$local';
  }

  static bool isValid(String input) => normalize(input) != null;

  /// Renders as `+251 91 234 5678` for display.
  static String pretty(String e164) {
    if (!e164.startsWith('+251')) return e164;
    final local = e164.substring(4);
    if (local.length != 9) return e164;
    return '+251 ${local.substring(0, 2)} ${local.substring(2, 5)} ${local.substring(5)}';
  }

  /// Masks the middle digits so a phone number is not exposed over a shoulder.
  static String masked(String e164) {
    if (e164.length < 5) return e164;
    return '${e164.substring(0, 4)}•••••${e164.substring(e164.length - 2)}';
  }
}

/// OTP entry validation.
///
/// Pure logic so the rules are unit tested rather than discovered on a handset.
abstract final class OtpValidator {
  OtpValidator._();

  /// Built once: interpolating the length into a RegExp each call would also
  /// work, but a precompiled pattern is easier to read and cannot drift.
  static final RegExp _shape = RegExp('^[0-9]{${AppConfig.otpLength}}\$');

  static bool isWellFormed(String code) => _shape.hasMatch(code.trim());

  /// Whether another attempt is permitted.
  ///
  /// The server also enforces this; checking locally avoids spending a request
  /// that is guaranteed to be rejected.
  static bool canAttempt({required int attemptsUsed, int max = AppConfig.maxOtpAttempts}) =>
      attemptsUsed < max;

  static int remainingAttempts(int used, [int max = AppConfig.maxOtpAttempts]) {
    final left = max - used;
    return left < 0 ? 0 : left;
  }
}

/// Where the user is in sign-in.
sealed class PassengerAuthState extends Equatable {
  const PassengerAuthState();

  @override
  List<Object?> get props => [];
}

/// No phone entered yet.
class PassengerAuthUnknown extends PassengerAuthState {
  const PassengerAuthUnknown();
}

/// Phone entered, waiting for the user to request a code.
class PassengerAuthPhoneEntered extends PassengerAuthState {
  const PassengerAuthPhoneEntered(this.phoneE164);
  final String phoneE164;

  @override
  List<Object?> get props => [phoneE164];
}

/// An SMS is on its way.
class PassengerAuthOtpSent extends PassengerAuthState {
  const PassengerAuthOtpSent({
    required this.phoneE164,
    required this.attemptsUsed,
    this.isResending = false,
  });

  final String phoneE164;
  final int attemptsUsed;
  final bool isResending;

  int get attemptsRemaining => OtpValidator.remainingAttempts(attemptsUsed);

  @override
  List<Object?> get props => [phoneE164, attemptsUsed, isResending];
}

/// Verifying the submitted code.
class PassengerAuthVerifying extends PassengerAuthState {
  const PassengerAuthVerifying(this.phoneE164, this.attemptsUsed);
  final String phoneE164;
  final int attemptsUsed;

  @override
  List<Object?> get props => [phoneE164, attemptsUsed];
}

/// Signed in.
class PassengerAuthAuthenticated extends PassengerAuthState {
  const PassengerAuthAuthenticated({required this.phoneE164, this.displayName});

  final String phoneE164;
  final String? displayName;

  @override
  List<Object?> get props => [phoneE164, displayName];
}

/// Something went wrong. [canRetry] drives whether Retry is offered.
class PassengerAuthFailure extends PassengerAuthState {
  const PassengerAuthFailure(this.message, {this.canRetry = true});

  final String message;
  final bool canRetry;

  @override
  List<Object?> get props => [message, canRetry];
}
