import 'package:addis_one/core/auth/app_role.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:addis_one/core/storage/token_storage.dart';

/// A passenger session and a staff session are different credentials for the
/// same server. Merging two binaries into one put them in the same keystore for
/// the first time, and a single unqualified key would have left both halves
/// writing to one slot.
void main() {
  late FlutterSecureStorage storage;

  setUp(() {
    storage = FlutterSecureStorage();
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('credentials are namespaced by role', () {
    test('a passenger token is invisible to the staff store', () async {
      final passenger = TokenStorage(role: AppRole.passenger, storage: storage);
      await passenger.save(
        accessToken: 'pax-token',
        refreshToken: 'pax-refresh',
        phone: '+251911000007',
      );

      final staff = TokenStorage(role: AppRole.staff, storage: storage);

      expect(await passenger.accessToken, 'pax-token');
      expect(
        await staff.accessToken,
        isNull,
        reason: 'the staff half must never send a passenger bearer token',
      );
      expect(await staff.refreshToken, isNull);
      expect(await staff.phone, isNull);
      expect(await staff.hasSession, isFalse);
    });

    test('a staff token is invisible to the passenger store', () async {
      final staff = TokenStorage(role: AppRole.staff, storage: storage);
      await staff.save(
        accessToken: 'staff-token',
        refreshToken: 'staff-refresh',
        phone: '+251911000008',
        employeeCode: 'EMP-42',
      );

      final passenger = TokenStorage(role: AppRole.passenger, storage: storage);

      expect(await staff.accessToken, 'staff-token');
      expect(await passenger.accessToken, isNull);
      expect(await passenger.refreshToken, isNull);
      expect(await passenger.phone, isNull);
      expect(await passenger.hasSession, isFalse);
    });

    test('signing out of one role leaves the other signed in', () async {
      // The normal case now that both live in one binary: a conductor rides to
      // work as a passenger, then inspects as staff on the same handset.
      final passenger = TokenStorage(role: AppRole.passenger, storage: storage);
      final staff = TokenStorage(role: AppRole.staff, storage: storage);
      await passenger.save(accessToken: 'pax', phone: '+251911000007');
      await staff.save(accessToken: 'staff', phone: '+251911000008');

      await staff.clearSession();

      expect(await staff.hasSession, isFalse);
      expect(
        await passenger.hasSession,
        isTrue,
        reason: 'ending a staff shift must not sign the passenger out',
      );
      // The remembered number survives too, so signing back in is one step.
      expect(await staff.phone, '+251911000008');
    });

    test('each role keeps its own remembered phone', () async {
      final passenger = TokenStorage(role: AppRole.passenger, storage: storage);
      final staff = TokenStorage(role: AppRole.staff, storage: storage);

      await passenger.save(accessToken: 'a', phone: '+251911000007');
      await staff.save(accessToken: 'b', phone: '+251911000008');

      expect(await passenger.phone, '+251911000007');
      expect(await staff.phone, '+251911000008');
    });
  });
}