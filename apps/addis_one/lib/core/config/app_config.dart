/// Build-time configuration for the single Addis One app.
///
/// One app serves both roles, so this is the union of what the two clients
/// previously declared. Keeping one object means a build cannot end up with a
/// passenger half pointed at one server and a staff half at another --?" the two
/// halves disagreed silently before, and a field build that validated against
/// the wrong environment was a support call nobody could explain.
///
/// The base URL is a compile-time constant so one build can be pointed at any
/// environment without a code change:
///
/// ```
/// flutter build apk --dart-define=API_BASE_URL=https://api.addis.one
/// ```
class AppConfig {
  const AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    // 10.0.2.2 is the host loopback as seen from the Android emulator. A
    // physical device must override this with the machine's LAN address, or
    // with 127.0.0.1 when `adb reverse` tunnels loopback over USB. The same host
    // must also be listed in network_security_config.xml for cleartext HTTP.
    defaultValue: 'http://10.0.2.2:3000/api/v1',
  );

  /// Whether the passenger half reads from the backend or bundled demo data.
  ///
  /// An explicit build flag rather than a runtime fallback: a build that cannot
  /// reach the backend should say so loudly, not quietly show invented fares
  /// that no conductor will honour.
  ///
  /// Defaults to **false**, and that default is the safety property rather than a
  /// matter of taste. A default of true made the most likely way to produce an
  /// APK --?" `flutter build apk --release`, with no dart-define --?" a build serving
  /// invented fares and itineraries to whoever installed it.
  ///
  /// Opting in is a deliberate act:
  ///
  /// ```
  /// flutter build apk --dart-define=USE_DEMO_DATA=true
  /// ```
  ///
  /// Staff surfaces are never faked. An inspector shown an invented verdict is
  /// worse than one shown no scanner at all, so this flag governs the passenger
  /// planner and vehicle lookup only.
  static const bool useDemoData = bool.fromEnvironment(
    'USE_DEMO_DATA',
    defaultValue: false,
  );

  /// Whether to *offer* the development sign-in control.
  ///
  /// Does not enable anything by itself. The server decides whether the route
  /// exists --?" `POST /auth/dev-login` 404s unless it is armed --?" and this only
  /// decides whether the app bothers to ask, so a release build never spends a
  /// round trip discovering a control it will not show.
  ///
  /// Default false because this control hands out a session without an OTP, and
  /// that must never be something a shipped build merely offers. Applies to both
  /// roles: the staff shortcut is the same server route with the same risk.
  static const bool enableDevSignIn = bool.fromEnvironment(
    'ENABLE_DEV_SIGN_IN',
    defaultValue: false,
  );

  /// Shown on the sign-in screens so nobody is misled about which build they are
  /// holding.
  static const String buildFlavour = String.fromEnvironment(
    'BUILD_FLAVOUR',
    defaultValue: 'live',
  );

  static const Duration requestTimeout = Duration(seconds: 15);

  /// OTP length. Six digits is the norm for Ethiopian mobile money services.
  static const int otpLength = 6;

  static const int maxOtpAttempts = 5;

  static const Duration otpTtl = Duration(minutes: 5);

  /// Minimum gap between two recorded scans.
  ///
  /// A single ticket held in the frame produces a continuous stream of
  /// detections, many per second. Without a floor the officer records the same
  /// passenger several times while reading the previous result --?" and for
  /// ALREADY_USED that manufactures fraud evidence against a paying passenger.
  static const Duration scanDebounce = Duration(milliseconds: 2500);

  /// How many recent scans to fetch for the history screen.
  static const int historyPageSize = 50;

  static const String appVersion = '1.0.0';
}