import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_failure.dart';
import '../../../../core/storage/token_storage.dart';
import '../../validation/data/scan_submitter.dart';
import 'staff_auth_state.dart';
import 'staff_repository.dart';

/// Drives the sign-in flow.
class StaffAuthController extends StateNotifier<StaffAuthState> {
  StaffAuthController({
    // ignore: prefer_initializing_formals
    required StaffRepository repo,
    // ignore: prefer_initializing_formals
    required TokenStorage tokens,
    // ignore: prefer_initializing_formals
    required ScanSubmitter submitter,
  })  :
        // ignore: prefer_initializing_formals
        _repo = repo,
        // ignore: prefer_initializing_formals
        _tokens = tokens,
        // ignore: prefer_initializing_formals
        _submitter = submitter,
        super(const StaffAuthState());

  final StaffRepository _repo;
  final TokenStorage _tokens;
  final ScanSubmitter _submitter;

  /// The remembered phone number, for the sign-in screen to prefill.
  ///
  /// Exposed as its own member rather than by having the UI read `state`, which
  /// is protected on StateNotifier: reading it from a widget is reaching past the
  /// controller's public surface to grab internals, and it would not survive the
  /// controller being replaced by a different implementation.
  String get rememberedPhone => state.phone;

  /// Ethiopian mobile numbers, matching the server's own validation.
  ///
  /// Checked here so the round trip is not spent on a number the API will reject
  /// anyway. The server validates independently either way — this is a
  /// convenience, not a security control.
  static final _phonePattern = RegExp(r'^\+251[79]\d{8}$');

  /// Restores a stored session at launch, and loads any remembered phone.
  Future<void> bootstrap() async {
    final phone = await _tokens.phone ?? '';
    if (!await _tokens.hasSession) {
      state = state.copyWith(stage: StaffAuthStage.signedOut, phone: phone);
      return;
    }

    // A stored token is not proof of a usable session: it may have expired, or
    // the officer may have been deactivated since. This call is what proves it,
    // and it also yields the role the rest of the app needs.
    try {
      final session = await _repo.session();
      unawaitedDrain();
      state = StaffAuthState(
        stage: StaffAuthStage.signedIn,
        session: session,
        phone: phone,
      );
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.unauthorized) {
        // Expired or revoked. Clearing is right: the officer must re-authenticate,
        // and leaving the token would only produce another 401 on the next tap.
        await _tokens.clearSession();
        state = StaffAuthState(stage: StaffAuthStage.signedOut, phone: phone);
        return;
      }
      // The server is unreachable, which says nothing about the token. Keep it
      // and let the officer work: a handheld with no signal at a stop is ordinary,
      // not a reason to sign someone out.
      state = state.copyWith(stage: StaffAuthStage.signedOut, phone: phone);
    }
  }

  /// Requests a verification code.
  Future<void> requestCode(String phone) async {
    if (!_phonePattern.hasMatch(phone)) {
      state = state.copyWith(
        error: 'Enter a valid Ethiopian mobile number, e.g. +251911000007',
      );
      return;
    }

    state = state.copyWith(
      stage: StaffAuthStage.submitting,
      phone: phone,
      clearError: true,
    );
    try {
      await _repo.requestOtp(phone);
      state = state.copyWith(stage: StaffAuthStage.awaitingCode);
    } on ApiException catch (e) {
      state = state.copyWith(
        stage: StaffAuthStage.signedOut,
        error: e.message ?? _friendly(e.failure),
      );
    }
  }

/// Completes sign-in with a code from the officer's message or the server log.
  Future<void> verifyCode(String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      state = state.copyWith(error: 'Enter the six-digit code.');
      return;
    }

    state = state.copyWith(stage: StaffAuthStage.submitting, clearError: true);
    try {
      await _repo.verifyOtp(state.phone, code);
      await _onSignedIn();
    } on ApiException catch (e) {
      // A wrong code is the common case and the message says so plainly rather
      // than implying the account is broken.
      state = state.copyWith(
        stage: StaffAuthStage.awaitingCode,
        error: e.message ?? _friendly(e.failure),
      );
    }
  }

  /// Signs in without a code, for field testing only.
  ///
  /// Takes the phone as an argument rather than reading [state] for it, for the
  /// same reason [requestCode] does: the number the officer typed lives in the
  /// text field until they submit it. Reading state here sent whatever a previous
  /// step had stored — usually nothing — so the shortcut failed with "not
  /// available" while the server was plainly working.
  Future<void> devSignIn(String phone) async {
    if (!_phonePattern.hasMatch(phone)) {
      state = state.copyWith(
        error: 'Enter a valid Ethiopian mobile number, e.g. +251911000007',
      );
      return;
    }

    state = state.copyWith(
      stage: StaffAuthStage.submitting,
      phone: phone,
      clearError: true,
    );
    try {
      final ok = await _repo.devSignIn(phone);
      if (!ok) {
        state = state.copyWith(
          stage: StaffAuthStage.signedOut,
          error: 'Development sign-in is not available on this server.',
        );
        return;
      }
      await _onSignedIn();
    } on ApiException catch (e) {
      state = state.copyWith(
        stage: StaffAuthStage.signedOut,
        error: e.message ?? _friendly(e.failure),
      );
    }
  }

  /// Returns to the number entry step without discarding what was typed.
  void backToPhone() {
    state = state.copyWith(stage: StaffAuthStage.signedOut, clearError: true);
  }

  Future<void> signOut() async {
    await _repo.signOut();
    state = StaffAuthState(stage: StaffAuthStage.signedOut, phone: state.phone);
  }

  Future<void> _onSignedIn() async {
    final session = await _repo.session();
    unawaitedDrain();
    state = state.copyWith(
      stage: StaffAuthStage.signedIn,
      session: session,
      clearError: true,
    );
  }

  /// Best-effort delivery of parked scans once a session exists.
  ///
  /// Deliberately not awaited: an officer should reach the scanner immediately,
  /// and a backlog of parked scans must not delay sign-in. A failure leaves the
  /// queue intact, which is safe because it is persisted.
  void unawaitedDrain() {
    // A try/catch in an async closure rather than catchError: this error path
    // has no value to return, and catchError would force inventing a
    // QueueDrainResult describing a drain that never happened.
    unawaited(_drainQuietly());
  }

  Future<void> _drainQuietly() async {
    try {
      await _submitter.drainPending();
    } catch (_) {
      // Swallowed on purpose. The queue is durable, so the scans are not lost —
      // they are retried on the next successful sign-in or refresh.
    }
  }

  static String _friendly(ApiFailure failure) => switch (failure) {
        ApiFailure.network => 'No connection to the server.',
        ApiFailure.unauthorized => 'Sign in again to continue.',
        ApiFailure.notFound => 'That service is not available.',
        ApiFailure.validation => 'That request was not accepted.',
        ApiFailure.server => 'The server had a problem. Try again shortly.',
        ApiFailure.timeout => 'The server had a problem. Try again shortly.',
        ApiFailure.unknown => 'The server had a problem. Try again shortly.',
        ApiFailure.cancelled => 'Cancelled.',
        ApiFailure.offline => 'No connection. The scan was saved locally.',
      };
}

