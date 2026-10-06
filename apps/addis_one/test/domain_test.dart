// Smoke test for the root widget.
//
// Deliberately shallow: it proves the app composes and reaches a signed-out
// state with no server, which is the failure that would otherwise only surface
// on a device at a bus stop. Behaviour of the scanner, the offline queue and the
// API layer is covered by unit tests against those units directly — pumping a
// camera preview in a widget test buys nothing. Those live in
// `api_client_test.dart` and `scan_queue_test.dart`; this file used to claim the
// offline queue was covered when nothing exercised it at all.
import 'package:addis_one/core/auth/app_role.dart';
import 'package:addis_one/core/models/staff_session.dart';
import 'package:addis_one/core/models/scan_outcome.dart';
import 'package:addis_one/core/storage/token_storage.dart';
import 'package:addis_one/features/staff/auth/domain/staff_auth_controller.dart';
import 'package:addis_one/features/staff/auth/domain/staff_auth_state.dart';
import 'package:addis_one/features/staff/auth/domain/staff_repository.dart';
import 'package:addis_one/features/staff/validation/data/scan_queue.dart';
import 'package:addis_one/features/staff/validation/data/scan_submitter.dart';
import 'package:flutter_test/flutter_test.dart';

/// A repository that must never be called during bootstrap.
///
/// Bootstrap short-circuits when no token is stored, so reaching any method here
/// would mean a regression has started making network calls on the splash path.
class _NeverCalledRepo implements StaffRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('bootstrap must not call the API');
}

/// Token storage with nothing stored, standing in for a first launch.
class _RecordingRepo implements StaffRepository {
  final phones = <String>[];

  @override
  Future<bool> devSignIn(String phone) async {
    phones.add(phone);
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyTokenStorage implements TokenStorage {
  _EmptyTokenStorage({required this.role});

  @override
  final AppRole role;

  @override
  Future<String?> get accessToken async => null;
  @override
  Future<String?> get refreshToken async => null;
  @override
  Future<String?> get phone async => null;
  @override
  Future<String?> get employeeCode async => null;
  @override
  Future<bool> get hasSession async => false;
  @override
  Future<void> save({
    required String accessToken,
    String? refreshToken,
    String? phone,
    String? employeeCode,
  }) async {}

  @override
  Future<void> clearSession() async {}
  @override
  Future<void> clearAll() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A submitter whose queue is empty and does nothing.
class _IdleSubmitter implements ScanSubmitter {
  @override
  Future<QueueDrainResult> drainPending() async =>
      const QueueDrainResult(delivered: 0, discarded: 0);

  @override
  Future<int> get pendingCount async => 0;

  @override
  Future<void> discardPending() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ScanOutcome', () {
    test('only VALID permits boarding', () {
      expect(ScanOutcome.valid.allowsBoarding, isTrue);
      expect(ScanOutcome.expired.allowsBoarding, isFalse);
      expect(ScanOutcome.alreadyUsed.allowsBoarding, isFalse);
      expect(ScanOutcome.revoked.allowsBoarding, isFalse);
      expect(ScanOutcome.notIssued.allowsBoarding, isFalse);
      expect(ScanOutcome.invalidSignature.allowsBoarding, isFalse);
      expect(ScanOutcome.unknown.allowsBoarding, isFalse);
    });

    test('parses the server vocabulary', () {
      expect(parseScanOutcome('VALID'), ScanOutcome.valid);
      expect(parseScanOutcome('ALREADY_USED'), ScanOutcome.alreadyUsed);
      expect(parseScanOutcome('INVALID_SIGNATURE'),
          ScanOutcome.invalidSignature);
    });

    test('an unrecognised outcome refuses rather than grants', () {
      // A newer server adding an outcome must not crash an older handheld, and
      // must certainly not be read as a clearance.
      expect(parseScanOutcome('SOMETHING_NEW'), ScanOutcome.unknown);
      expect(parseScanOutcome(null), ScanOutcome.unknown);
      expect(parseScanOutcome('SOMETHING_NEW').allowsBoarding, isFalse);
    });
  });

  group('ScanResult', () {
    test('a missing accepted flag falls back to the outcome', () {
      final result = ScanResult.fromJson(const {
        'outcome': 'EXPIRED',
        'reason': 'The ticket expired.',
        'validatedAt': '2026-10-04T02:00:00.000Z',
        'validationReference': 'VAL-1',
      });
      expect(result.accepted, isFalse);
      expect(result.allowsBoarding, isFalse);
    });

    test('a valid ticket without an accepted flag is still accepted', () {
      final result = ScanResult.fromJson(const {
        'outcome': 'VALID',
        'reason': 'Ticket is valid for boarding.',
        'validatedAt': '2026-10-04T02:00:00.000Z',
        'validationReference': 'VAL-2',
      });
      expect(result.accepted, isTrue);
    });

    test('flags an audit row the server could not write', () {
      final result = ScanResult.fromJson(const {
        'outcome': 'INVALID',
        'accepted': false,
        'reason': 'Unreadable.',
        'validatedAt': '2026-10-04T02:00:00.000Z',
        'validationReference': 'UNRECORDED',
      });
      expect(result.isUnrecorded, isTrue);
    });
  });

  group('StaffSession', () {
    test('names the officer from the staff-session payload', () {
      final session = StaffSession.fromJson(const {
        'staff': {
          'displayName': 'Selassie I Inspector',
          'employeeCode': 'TB-009',
          'role': 'INSPECTOR',
          'operatorId': 'op-1',
          'display': 'Selassie I Inspector',
        },
        'permissions': {'canValidate': true, 'canManage': false},
      });
      expect(session.displayName, 'Selassie I Inspector');
      expect(session.role, 'INSPECTOR');
      expect(session.canValidate, isTrue);
      expect(session.operatorId, 'op-1');
    });

    test('the server decides whether the role may scan', () {
      // Regression test. The client used to recompute this from its own copy of
      // SCAN_ROLES while the server enforced a different list, so a handheld
      // could offer a scan the server refuses. Trusting the server closes that.
      const payload = {
        'staff': {'role': 'DRIVER', 'display': 'Selassie I Driver'},
        // A driver is in no scanning list, so the server must answer false —
        // and must be believed even though the client's table is irrelevant here.
        'permissions': {'canValidate': false},
      };
      expect(StaffSession.fromJson(payload).canValidate, isFalse);
    });

    test('an older server without the flag still yields a usable answer', () {
      final session = StaffSession.fromJson(const {
        'staff': {'role': 'INSPECTOR', 'display': 'Selassie I Inspector'},
        'permissions': <String, dynamic>{},
      });
      expect(session.canValidate, isTrue);
    });
  });

  group('StaffAuthState', () {
    test('starts unknown so the splash is not skipped', () {
      expect(const StaffAuthState().stage, StaffAuthStage.unknown);
    });

    test('copyWith clears the error only when asked', () {
      const state = StaffAuthState(error: 'nope');
      expect(state.copyWith(stage: StaffAuthStage.signedOut).error, 'nope');
      expect(
        state.copyWith(stage: StaffAuthStage.signedOut, clearError: true).error,
        isNull,
      );
    });
  });

  group('bootstrap', () {
    // Regression test for a deadlock that only showed up on a real device: the
    // splash waited for a bootstrap that was started by SignInScreen, which is
    // not mounted until the splash has already given way. The app sat on the
    // splash forever and logged nothing.
    //
    // Every unit test passed while this was broken, because none of them started
    // from `unknown` and waited for the transition out of it.
    test('leaves the unknown stage even with no stored session', () async {
      final controller = StaffAuthController(
        repo: _NeverCalledRepo(),
        tokens: _EmptyTokenStorage(role: AppRole.staff),
        submitter: _IdleSubmitter(),
      );
      addTearDown(controller.dispose);

      expect(controller.state.stage, StaffAuthStage.unknown);
      await controller.bootstrap();

      expect(controller.state.stage, StaffAuthStage.signedOut);
    });

    test('keeps an unreachable server from signing the officer out silently',
        () async {
      // No session stored, but bootstrap must still resolve to a real screen
      // rather than stranding the user on the splash.
      final controller = StaffAuthController(
        repo: _NeverCalledRepo(),
        tokens: _EmptyTokenStorage(role: AppRole.staff),
        submitter: _IdleSubmitter(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      expect(controller.state.stage, isNot(StaffAuthStage.unknown));
    });

    // Regression test: the shortcut button used to read the phone from state,
    // which is empty until "Send verification code" is pressed. On a real device
    // that meant the officer's number was never sent, and the shortcut failed
    // with "not available" against a server that was working fine.
    test('devSignIn sends the number it was given, not a stale one', () async {
      final repo = _RecordingRepo();
      final controller = StaffAuthController(
        repo: repo,
        tokens: _EmptyTokenStorage(role: AppRole.staff),
        submitter: _IdleSubmitter(),
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();

      await controller.devSignIn('+251911000007');

      expect(repo.phones, ['+251911000007']);
    });

    test('devSignIn refuses a malformed number without calling the server',
        () async {
      final repo = _RecordingRepo();
      final controller = StaffAuthController(
        repo: repo,
        tokens: _EmptyTokenStorage(role: AppRole.staff),
        submitter: _IdleSubmitter(),
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();

      await controller.devSignIn('4');

      expect(repo.phones, isEmpty);
      expect(controller.state.error, contains('valid Ethiopian mobile'));
    });
  });
}
