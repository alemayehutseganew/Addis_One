import 'package:equatable/equatable.dart';
import 'package:intl/intl.dart';

/// Money, matching the backend contract exactly.
///
/// The whole system uses **integer minor units (fils)**; 1 ETB = 100 fils.
/// Dart doubles are IEEE-754 and cannot represent 0.10 exactly, so a fare of
/// 25.00 ETB stored as a double drifts and produces reconciliation failures that
/// surface months later in settlement reports.
///
/// This type makes floats unrepresentable rather than merely discouraged: the
/// constructor rejects non-integers, and there is no way to hold a fractional
/// fil.
class Money extends Equatable {
  /// Const constructor for compile-time amounts (fares in constants, defaults).
  /// A non-empty currency check cannot be const, so it is skipped here — an
  /// empty currency literal in source is caught by tests, not at runtime.
  const Money(this.fils, {this.currency = defaultCurrency});

  /// Builds from integer fils with runtime validation.
  factory Money.validated(int fils, {String currency = defaultCurrency}) {
    if (currency.isEmpty) {
      throw ArgumentError.value(currency, 'currency', 'must not be empty');
    }
    return Money(fils, currency: currency);
  }

  /// Parses a decimal string such as "25.00" or "12.5".
  ///
  /// String input is safe because it is parsed digit-wise — going through a
  /// double first would reintroduce exactly the error this class prevents.
  factory Money.parse(String value, {String currency = defaultCurrency}) {
    final cleaned = value.trim().replaceAll(RegExp(r'[^0-9.\-]'), '');
    final parts = cleaned.split('.');
    if (parts.isEmpty || parts.first.isEmpty) {
      throw FormatException('Not a valid amount: $value', value);
    }
    if (parts.length > 2) {
      throw FormatException('Too many decimal places: $value', value);
    }

    final major = int.parse(parts.first);
    final minorPart = parts.length == 2 ? parts[1] : '0';
    if (minorPart.length > 2) {
      throw FormatException(
        'Amount has sub-fil precision, which cannot be stored: $value',
        value,
      );
    }
    final minor = int.parse(minorPart.padRight(2, '0'));
    final sign = major < 0 ? -1 : 1;
    return Money(sign * (major.abs() * 100 + minor), currency: currency);
  }

  static const String defaultCurrency = 'ETB';
  static const int filsPerMajor = 100;

  /// Integer minor units. The only authoritative representation.
  final int fils;
  final String currency;

  /// Zero fare. Const so it can be used as a default parameter value.
  static const Money zero = Money(0);

  Money operator +(Money other) {
    _assertSameCurrency(other);
    return Money(fils + other.fils, currency: currency);
  }

  Money operator -(Money other) {
    _assertSameCurrency(other);
    return Money(fils - other.fils, currency: currency);
  }

  /// Scales by an integer count of identical amounts — the fare for a group of
  /// [count] passengers.
  ///
  /// The multiplier is an **int** on purpose. Taking a double here would
  /// reintroduce exactly the drift this class exists to prevent: 1500 fils
  /// times 3 must be 4500 exactly, and `1500 * 3.0` is a float the moment it is
  /// written. Integer fils times an integer count is exact by construction.
  Money operator *(int count) => Money(fils * count, currency: currency);

  /// This fare for [count] passengers.
  Money times(int count) => this * count;

  /// Scales by an integer percentage, rounding half-up.
  ///
  /// Percentage is an int so the intermediate stays exact; a double percentage
  /// would reintroduce float drift at exactly the point this class forbids it.
  Money percentageOf(int percent) {
    return Money((fils * percent / 100).round(), currency: currency);
  }

  bool get isZero => fils == 0;
  bool get isNegative => fils < 0;
  bool get isPositive => fils > 0;

  /// Major units as a double — for display and charting only, never storage.
  double get majorUnits => fils / filsPerMajor;

  /// e.g. "25.00"
  String get plain => (fils / filsPerMajor).toStringAsFixed(2);

  /// e.g. "25.00 ETB"
  String get display => '$plain $currency';

  /// Locale-aware display. Amharic renders Eastern Arabic numerals.
  String displayFor(String localeCode) {
    final format = NumberFormat.currency(
      locale: localeCode == 'am' ? 'am_ET' : 'en_ET',
      symbol: currency,
      decimalDigits: 2,
    );
    return format.format(majorUnits);
  }

  void _assertSameCurrency(Money other) {
    if (other.currency != currency) {
      throw ArgumentError(
        'Currency mismatch: cannot combine $currency with ${other.currency}',
      );
    }
  }

  @override
  List<Object?> get props => [fils, currency];

  @override
  String toString() => 'Money($plain $currency)';
}
