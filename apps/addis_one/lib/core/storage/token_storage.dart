import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/app_role.dart';

/// Session token storage.
///
/// Uses the platform keystore (Android EncryptedSharedPreferences, iOS Keychain)
/// rather than SharedPreferences. Both kinds of session token are bearer
/// credentials: anything that can read a passenger's token can buy tickets on
/// their account, and anything that can read a staff token inherits that
/// officer's authority over revenue, fares and the network. Neither may sit in
/// plaintext app storage.
///
/// ## Why the role is a constructor argument
///
/// The two apps were separate binaries, so each had one unambiguous token. This
/// app serves both roles, which creates a hazard that did not exist before: a
/// single `TokenStorage` with unqualified keys would have exactly one slot for
/// "the current token", and the two halves would fight over it. Binding the role
/// into the instance gives every call site the right namespace without any of
/// them having to remember which half it belongs to: the mistake a caller cannot
/// make is the one this design removes.
///
/// Keys are namespaced as `addis_one_<role>_...`, which also keeps an upgrade
/// from an older single-role build reading a token written for the other role.
class TokenStorage {
  TokenStorage({
    required this.role,
    FlutterSecureStorage? storage,
  }) : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  /// Which credential namespace this instance reads and writes.
  final AppRole role;

  final FlutterSecureStorage _storage;

  late final String _accessKey = 'addis_one_${role.storagePrefix}_access_token';
  late final String _refreshKey = 'addis_one_${role.storagePrefix}_refresh_token';
  late final String _phoneKey = 'addis_one_${role.storagePrefix}_phone';

  /// Only the staff half records an employee code; a passenger has none.
  late final String _employeeKey =
      'addis_one_${role.storagePrefix}_employee_code';

  Future<String?> get accessToken => _storage.read(key: _accessKey);

  Future<String?> get refreshToken => _storage.read(key: _refreshKey);

  Future<String?> get phone => _storage.read(key: _phoneKey);

  Future<String?> get employeeCode => _storage.read(key: _employeeKey);

  Future<bool> get hasSession async => (await accessToken)?.isNotEmpty ?? false;

  Future<void> save({
    required String accessToken,
    String? refreshToken,
    String? phone,
    String? employeeCode,
  }) async {
    await _storage.write(key: _accessKey, value: accessToken);
    if (refreshToken != null) {
      await _storage.write(key: _refreshKey, value: refreshToken);
    }
    if (phone != null) {
      await _storage.write(key: _phoneKey, value: phone);
    }
    if (employeeCode != null) {
      await _storage.write(key: _employeeKey, value: employeeCode);
    }
  }

  /// Clears the session but keeps the remembered phone, so signing in again is a
  /// one-step code entry rather than retyping a number on a small screen in poor
  /// light.
  ///
  /// Deliberately scoped to this role: signing a staff officer out must not also
  /// sign out a passenger who shares the handset, which is the normal case now
  /// that both live in one binary.
  Future<void> clearSession() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }

  Future<void> clearAll() async {
    await clearSession();
    await _storage.delete(key: _phoneKey);
    await _storage.delete(key: _employeeKey);
  }
}