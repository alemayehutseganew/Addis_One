import 'dart:convert';

import 'package:equatable/equatable.dart';

/// The passenger ticket QR credential — the Dart mirror of the backend
/// `CredentialSigner`.
///
/// Two properties are load-bearing and must match the server byte-for-byte:
///
///  1. **Canonical serialisation.** The signed string is built in a fixed field
///     order joined by `|`. Dart's `jsonEncode` does not guarantee key order,
///     so the payload is flattened explicitly rather than stringifying a map.
///     If this and `credential-signer.ts` disagree, every ticket fails
///     verification — which is why the format is versioned.
///
///  2. **No commercial data.** The payload carries identifiers, timestamps, a
///     nonce, a key id and a signature. No fare, no user, no route. A screenshot
///     of someone's QR reveals nothing about them and cannot be altered to
///     change what they paid.
///
/// This class only *parses and serialises*. Signature verification needs
/// Ed25519, which lives in the staff app (see `qr_verifier.dart`); the passenger
/// app only renders the credential the server returned.
class QrCredential extends Equatable {
  const QrCredential({
    required this.ticketId,
    required this.credentialId,
    required this.issuedAt,
    required this.expiresAt,
    required this.nonce,
    required this.keyId,
    required this.signature,
    this.version = currentVersion,
  });

  /// Wire version. Bumped only for a breaking format change.
  static const int currentVersion = 1;

  /// Short wire keys. Kept terse because every byte is rendered into a QR image
  /// that must scan reliably on a cracked phone screen.
  final int version;
  final String ticketId;
  final String credentialId;
  final int issuedAt; // unix seconds
  final int expiresAt; // unix seconds
  final String nonce;
  final String keyId;
  final String signature; // base64

  DateTime get issuedAtDate => DateTime.fromMillisecondsSinceEpoch(issuedAt * 1000);
  DateTime get expiresAtDate => DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);

  bool isExpiredAt(DateTime now) => now.isAfter(expiresAtDate);

  Duration remainingAt(DateTime now) => expiresAtDate.difference(now);

  /// The exact string that gets signed.
  ///
  /// Field order is part of the contract. Do not reorder.
  String canonicalPayload() {
    return [
      version,
      ticketId,
      credentialId,
      issuedAt,
      expiresAt,
      nonce,
    ].join('|');
  }

  /// The exact string encoded into the QR image.
  String toQrString() => jsonEncode({
        't': ticketId,
        'c': credentialId,
        'i': issuedAt,
        'e': expiresAt,
        'n': nonce,
        'k': keyId,
        's': signature,
      });

  /// Parses a scanned or stored QR string.
  ///
  /// Returns null on anything malformed rather than throwing: a bad QR is an
  /// expected input, not an exceptional one.
  static QrCredential? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return QrCredential.fromJson(decoded);
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }

  factory QrCredential.fromJson(Map<String, dynamic> json) {
    final t = json['t'];
    final c = json['c'];
    final i = json['i'];
    final e = json['e'];
    final n = json['n'];
    final k = json['k'];
    final s = json['s'];

    if (t is! String ||
        c is! String ||
        i is! int ||
        e is! int ||
        n is! String ||
        k is! String ||
        s is! String) {
      throw const FormatException('Malformed QR credential payload');
    }

    return QrCredential(
      ticketId: t,
      credentialId: c,
      issuedAt: i,
      expiresAt: e,
      nonce: n,
      keyId: k,
      signature: s,
    );
  }

  @override
  List<Object?> get props =>
      [version, ticketId, credentialId, issuedAt, expiresAt, nonce, keyId, signature];
}
