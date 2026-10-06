// Regression tests for the server-declared capability set.
//
// The app renders its entire menu from `capabilities`, so these are the tests
// that stand between "the server said no" and "the handheld offered a button
// that could only ever 403". The rule being defended is the same one
// backend/src/modules/auth/policy.ts states: the client never carries its own
// role table.
//
// The failure this is modelled on is real. `canValidate` was once recomputed on
// the client from a duplicated list of roles; the two answers drifted and a
// handheld offered a scan the server refused.
import 'package:addis_one/core/models/staff_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a staff-session envelope with the given capability flags.
Map<String, dynamic> _sessionPayload(
  Map<String, bool> capabilities, {
  Map<String, dynamic>? permissions,
  String role = 'INSPECTOR',
}) {
  return {
    'staff': {'display': 'Test Officer', 'role': role},
    'permissions': ?permissions,
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
  };
}

void main() {
  group('StaffCapabilities', () {
    test('is all-false by default, never all-true', () {
      // A default-true set would be a build offering every surface to a role the
      // server has not told us about. The failure direction that matters here is
      // silence, not permission.
      const caps = StaffCapabilities();
      expect(caps.isEmpty, isTrue);
      expect(caps.canScan, isFalse);
      expect(caps.canManageNetwork, isFalse);
      expect(caps.canManageStaff, isFalse);
      expect(caps.cityWide, isFalse);
    });

    test('reads only an explicit true', () {
      // `== true` rather than truthiness: a server sending the string "false" is
      // a bug, and reading it as permission would turn that bug into access.
      final caps = StaffCapabilities.fromJson(const {
        'canScan': true,
        'canViewReports': 'true',
        'canManageStaff': 1,
      });
      expect(caps.canScan, isTrue);
      expect(caps.canViewReports, isFalse);
      expect(caps.canManageStaff, isFalse);
    });

    test('a null or absent block grants nothing', () {
      expect(StaffCapabilities.fromJson(null).isEmpty, isTrue);
      expect(StaffCapabilities.fromJson(const {}).isEmpty, isTrue);
    });

    test('city-wide scope is separate from any capability', () {
      // An operator admin administers one operator. That is about the *shape* of
      // the data they see, not a permission, so it must not be inferred from
      // holding any rights at all.
      final caps = StaffCapabilities.fromJson(const {'canManageNetwork': true});
      expect(caps.canManageNetwork, isTrue);
      expect(caps.cityWide, isFalse);
    });
  });

  group('StaffSession reads the declared capabilities', () {
    test('prefers the capabilities block over the legacy field', () {
      final session = StaffSession.fromJson(_sessionPayload(
        const {'canScan': false, 'canOperateTrips': true},
        // The two disagree deliberately: `permissions` is the older field and
        // must not win, or this build falls back to the drift the test exists to
        // prevent.
        permissions: const {'canValidate': true},
        role: 'DRIVER',
      ));

      expect(session.capabilities.canScan, isFalse);
      expect(session.capabilities.canOperateTrips, isTrue);
      // The legacy field is still parsed for older builds; only the new one
      // steers this build.
      expect(session.canValidate, isTrue);
    });

    test('falls back to the legacy field when the server sends no block', () {
      // An older backend. The officer must still reach the one surface they had,
      // rather than being silently locked out by a missing key.
      final session = StaffSession.fromJson(_sessionPayload(
        const {},
        permissions: const {'canValidate': true},
      ));
      expect(session.capabilities.canScan, isTrue);
    });

    test('a legacy server that denied scanning still denies it', () {
      final session = StaffSession.fromJson(_sessionPayload(
        const {},
        permissions: const {'canValidate': false},
        role: 'DRIVER',
      ));
      expect(session.capabilities.canScan, isFalse);
      expect(session.capabilities.isEmpty, isTrue);
    });

    test('an inspector is offered scanning and nothing else', () {
      final session = StaffSession.fromJson(_sessionPayload(
        const {'canScan': true, 'cityWide': false},
        role: 'INSPECTOR',
      ));
      expect(session.capabilities.canScan, isTrue);
      expect(session.capabilities.canOperateTrips, isFalse);
      expect(session.capabilities.canManageShift, isFalse);
      expect(session.capabilities.canViewReports, isFalse);
      expect(session.capabilities.canManageNetwork, isFalse);
      expect(session.capabilities.canManageStaff, isFalse);
    });

    test('a driver is offered trips and shifts but never the scanner', () {
      final session = StaffSession.fromJson(_sessionPayload(
        const {
          'canOperateTrips': true,
          'canManageShift': true,
          'canScan': false,
        },
        role: 'DRIVER',
      ));
      expect(session.capabilities.canOperateTrips, isTrue);
      expect(session.capabilities.canManageShift, isTrue);
      expect(session.capabilities.canScan, isFalse);
    });

    test('an auditor may approve fares but may not author them', () {
      // The asymmetry is the backend's, and the app must not flatten it into a
      // single "manage fares" flag.
      final session = StaffSession.fromJson(_sessionPayload(
        const {'canApproveFares': true, 'canAuthorFares': false},
        role: 'AUDITOR',
      ));
      expect(session.capabilities.canApproveFares, isTrue);
      expect(session.capabilities.canAuthorFares, isFalse);
    });

    test('city-wide roles carry the flag the server set', () {
      final session = StaffSession.fromJson(_sessionPayload(
        const {'canViewFinance': true, 'cityWide': true},
        role: 'FINANCE',
      ));
      expect(session.capabilities.cityWide, isTrue);
      expect(session.isOperatorScoped, isFalse);
    });

    test('capabilities take part in equality', () {
      // Equatable, so two sessions differing only in capabilities must not
      // compare equal — otherwise a rebuild after a role change would look like
      // no change at all and the menu would stay stale.
      final a = StaffSession.fromJson(_sessionPayload(const {'canScan': true}));
      final b = StaffSession.fromJson(_sessionPayload(const {'canScan': false}));
      expect(a, isNot(b));
    });

    test('a malformed capabilities block is treated as absent, not fatal', () {
      // A string where a map should be is a server bug, and the two reasonable
      // responses are "crash" and "fall back". Falling back is right: it keeps an
      // older or broken deployment usable, and it fails in the safe direction
      // because the legacy path derives from `permissions`, which the server
      // still enforces. What must not happen is an unhandled cast.
      final session = StaffSession.fromJson({
        'staff': {'role': 'INSPECTOR', 'display': 'X'},
        'permissions': {'canValidate': true},
        'capabilities': 'not an object',
      });
      expect(session.capabilities.isEmpty, isFalse);
      expect(session.capabilities.canScan, isTrue);
      expect(session.displayName, 'X');
    });

    test('a malformed block from a server that denied scanning stays denied', () {
      final session = StaffSession.fromJson({
        'staff': {'role': 'DRIVER', 'display': 'X'},
        'permissions': {'canValidate': false},
        'capabilities': 42,
      });
      expect(session.capabilities.canScan, isFalse);
      expect(session.capabilities.isEmpty, isTrue);
    });
  });
}
