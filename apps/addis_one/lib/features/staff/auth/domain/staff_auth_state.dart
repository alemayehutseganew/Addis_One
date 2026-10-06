import 'package:equatable/equatable.dart';

import '../../../../core/models/staff_session.dart';

/// Where the officer is in the sign-in flow.
enum StaffAuthStage {
  /// Reading the stored session at launch.
  unknown,

  /// No valid session; the sign-in screen is shown.
  signedOut,

  /// A code has been sent and is being awaited.
  awaitingCode,

  /// Verifying a code or the dev bypass.
  submitting,

  /// Signed in, with the session loaded.
  signedIn,
}

/// Sign-in state.
///
/// [session] is loaded after the token is stored rather than before, so every
/// screen that reads it has a role to branch on. Rendering the scanner before
/// the role is known would let a driver reach a scan button that is guaranteed
/// to 403.
class StaffAuthState extends Equatable {
  const StaffAuthState({
    this.stage = StaffAuthStage.unknown,
    this.session,
    this.phone = '',
    this.error,
  });

  final StaffAuthStage stage;
  final StaffSession? session;

  /// The number being signed in to, carried across steps so the officer does not
  /// retype it on a small screen in poor light.
  final String phone;

  final String? error;

  StaffAuthState copyWith({
    StaffAuthStage? stage,
    StaffSession? session,
    String? phone,
    String? error,
    bool clearError = false,
  }) {
    return StaffAuthState(
      stage: stage ?? this.stage,
      session: session ?? this.session,
      phone: phone ?? this.phone,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [stage, session, phone, error];
}
