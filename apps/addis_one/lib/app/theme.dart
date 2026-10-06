import 'package:flutter/material.dart';

import '../core/models/scan_outcome.dart';

/// Addis One visual language.
///
/// Ethiopian flag colours are used deliberately but restrained --?" a transport app
/// is used in bright sun and at a glance, so contrast carries more weight than
/// decoration. Green/Yellow/Red appear as accents, never as large fills behind
/// body text.
///
/// One theme for both roles. The two apps each had their own, and keeping them
/// would have meant a `Theme` swap at every role boundary --?" a passenger tapping
/// "Staff" and landing in a differently-styled app reads as two apps stapled
/// together, which is precisely what this merge exists to avoid. The staff
/// palette survives intact below; only the mechanism for reaching it changed.
abstract final class AppColors {
  /// Flag green. Primary brand colour.
  static const green = Color(0xFF0F8B4D);
  static const greenDark = Color(0xFF0A6B3B);
  static const greenLight = Color(0xFFE6F4EC);

  /// Flag yellow. Accent for CTAs and highlights.
  static const yellow = Color(0xFFF2C230);
  static const yellowDark = Color(0xFFD9A520);
  static const yellowLight = Color(0xFFFEF7E0);

  /// Flag red. Reserved for errors and destructive actions only.
  static const red = Color(0xFFC62828);
  static const redLight = Color(0xFFFDECEC);

  static const ink = Color(0xFF14201C);
  static const inkMuted = Color(0xFF5B6B65);
  static const surface = Color(0xFFFFFFFF);
  static const background = Color(0xFFF6F8F7);
  static const divider = Color(0xFFE3E9E6);

  /// Transport mode colours, used consistently across planner and tickets.
  static const modeBus = Color(0xFF1D6FE0);
  static const modeTaxi = Color(0xFFF29900);
  static const modeTrain = Color(0xFF8E44AD);
  static const modeWalk = Color(0xFF7F8C8D);

  /// Boarding permitted.
  ///
  /// Deliberately a different green from [green]: a verdict is read by an
  /// officer at arm's length in a moving vehicle, and a colour that also means
  /// "brand" everywhere else would dilute the one moment it has to be
  /// unambiguous.
  static const verdictAccept = Color(0xFF0F7B3D);

  /// Refused. Distinct from [verdictAccept] in lightness as well as hue, so the
  /// pair remains separable in monochrome and for a colour-blind reader.
  static const verdictRefuse = Color(0xFFB3261E);

  /// Could not determine --?" offline, or an outcome this build does not know.
  static const verdictUnknown = Color(0xFF8A5A00);
}

/// The staff half's own accent green.
///
/// Darker than [AppColors.green] and used for staff app bars and chrome, so an
/// officer holding the handset can tell at a glance which half of the app they
/// are in. The distinction matters more now than it did when the two were
/// separate binaries: the same person can hold the same device in both roles.
abstract final class StaffColors {
  static const green = Color(0xFF006A4D);
  static const greenDark = Color(0xFF004C37);
}

/// Supported locales. Amharic and English ship at launch.
///
/// Applied across both roles. Staff surfaces are English-only today, which is
/// why no Amharic copy was written for them --?" but routing them through the same
/// scope means adding it later is copy, not architecture.
enum AppLocale {
  am('am', '--S--^>--^--S>'),
  en('en', 'English');

  const AppLocale(this.code, this.nativeLabel);
  final String code;
  final String nativeLabel;
}

/// Spacing scale, used everywhere instead of magic numbers.
/// Spacing scale, used everywhere instead of magic numbers.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

/// Corner radii, likewise a scale rather than per-call magic numbers.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 20;
}

abstract final class AppTheme {
  /// Line heights above 1.3 are deliberate: Ethiopic glyphs have tall ascenders
  /// and descenders that clip at the default 1.0--?"1.2.
  static TextTheme _textTheme() => const TextTheme(
        displaySmall: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1.35),
        headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.35),
        headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.4),
        titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.4),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.45),
        bodyLarge: TextStyle(fontSize: 16, height: 1.55),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5),
        bodySmall: TextStyle(fontSize: 12, height: 1.5),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.25),
        labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.25),
      );

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.green,
        primary: AppColors.green,
        secondary: AppColors.yellow,
        error: AppColors.red,
        surface: AppColors.surface,
      ),
      scaffoldBackgroundColor: AppColors.background,
      textTheme: _textTheme(),
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.ink,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: const BorderSide(color: AppColors.divider),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          // 56dp, the larger of the two original values: comfortably tappable with
          // gloves on, in a moving vehicle. The passenger half used 52.
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.green,
          side: const BorderSide(color: AppColors.green),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.green, width: 2),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.greenLight,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
/// Presentation of a scan outcome.
///
/// Kept beside the theme rather than inside the model: the model is the wire
/// vocabulary and must not acquire opinions about colour.
///
/// Built around one requirement the passenger app does not have: an officer
/// reads the result from arm's length, in a moving vehicle, often in bright sun
/// or at dusk. So the verdict colours are chosen for maximum separation and the
/// verdict is carried by an icon and a word as well as a hue - never by colour
/// alone, which would be unreadable to a colour-blind officer and useless in
/// glare.
extension ScanOutcomePresentation on ScanOutcome {
  Color get color => switch (this) {
        ScanOutcome.valid => AppColors.verdictAccept,
        ScanOutcome.expired ||
        ScanOutcome.alreadyUsed ||
        ScanOutcome.revoked ||
        ScanOutcome.notIssued =>
          AppColors.verdictRefuse,
        ScanOutcome.unknown => AppColors.verdictUnknown,
        _ => AppColors.verdictRefuse,
      };

  IconData get icon => switch (this) {
        ScanOutcome.valid => Icons.check_circle,
        ScanOutcome.expired => Icons.schedule,
        ScanOutcome.alreadyUsed => Icons.history,
        ScanOutcome.revoked => Icons.block,
        ScanOutcome.notIssued => Icons.pending_outlined,
        ScanOutcome.invalidSignature => Icons.gpp_bad,
        ScanOutcome.unknownCredential => Icons.help_outline,
        ScanOutcome.wrongTrip => Icons.wrong_location,
        ScanOutcome.wrongMode => Icons.directions_bus_outlined,
        ScanOutcome.notYetValid => Icons.av_timer,
        ScanOutcome.invalid => Icons.qr_code_2,
        ScanOutcome.unknown => Icons.cloud_off,
      };

  /// Short headline. The server's `ScanResult.reason` carries the detail; this
  /// is what an officer registers at a glance.
  String get headline => switch (this) {
        ScanOutcome.valid => 'VALID',
        ScanOutcome.expired => 'EXPIRED',
        ScanOutcome.alreadyUsed => 'ALREADY USED',
        ScanOutcome.revoked => 'REVOKED',
        ScanOutcome.notIssued => 'NOT ISSUED',
        ScanOutcome.invalidSignature => 'BAD SIGNATURE',
        ScanOutcome.unknownCredential => 'NOT A TICKET',
        ScanOutcome.wrongTrip => 'WRONG TRIP',
        ScanOutcome.wrongMode => 'WRONG MODE',
        ScanOutcome.notYetValid => 'NOT YET VALID',
        ScanOutcome.invalid => 'INVALID',
        ScanOutcome.unknown => 'PENDING',
      };
}

