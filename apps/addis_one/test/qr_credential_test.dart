import 'dart:convert';
import 'dart:io';

import 'package:addis_one/core/models/qr_credential.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cross-language contract test.
///
/// These vectors were produced by the REAL backend signer
/// (`backend/src/tools/emit-vectors.ts`), not by a hand-written copy. This
/// test is what stops the Dart and TypeScript implementations of the QR
/// credential format from drifting: if either side changes its canonical
/// serialisation, this fails.
///
/// A drift here would not be a cosmetic bug — it would make every ticket
/// issued in production fail validation.
void main() {
  final fixture = jsonDecode(
    File('test/vectors/qr_credential_vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final vectors = (fixture['vectors'] as List).cast<Map<String, dynamic>>();

  group('QR credential cross-language contract', () {
    test('fixture is populated', () {
      expect(vectors, isNotEmpty,
          reason: 'Backend vector fixture must not be empty');
    });

    test('Dart reproduces the backend canonical payload exactly', () {
      for (final v in vectors) {
        final credential = QrCredential(
          ticketId: v['ticketId'] as String,
          credentialId: v['credentialId'] as String,
          issuedAt: v['issuedAt'] as int,
          expiresAt: v['expiresAt'] as int,
          nonce: v['nonce'] as String,
          keyId: v['keyId'] as String,
          signature: v['signature'] as String,
        );

        expect(
          credential.canonicalPayload(),
          v['canonicalPayload'],
          reason: 'Canonical payload drifted for ${v['ticketId']}. '
              'The Dart and backend serialisations must stay identical.',
        );
      }
    });

    test('Dart parses a backend-produced QR string losslessly', () {
      for (final v in vectors) {
        final parsed = QrCredential.tryParse(v['qrString'] as String);
        expect(parsed, isNotNull, reason: 'Failed to parse ${v['ticketId']}');

        expect(parsed!.ticketId, v['ticketId']);
        expect(parsed.credentialId, v['credentialId']);
        expect(parsed.issuedAt, v['issuedAt']);
        expect(parsed.expiresAt, v['expiresAt']);
        expect(parsed.nonce, v['nonce']);
        expect(parsed.keyId, v['keyId']);
        expect(parsed.signature, v['signature']);
      }
    });

    test('re-serialising a parsed credential reproduces the same QR string', () {
      for (final v in vectors) {
        final parsed = QrCredential.tryParse(v['qrString'] as String)!;
        expect(
          parsed.toQrString(),
          v['qrString'],
          reason: 'Round-trip changed the QR payload for ${v['ticketId']}',
        );
      }
    });

    test('QR payload carries no commercial data (I4)', () {
      for (final v in vectors) {
        final raw = (v['qrString'] as String).toLowerCase();
        for (final forbidden in const [
          'fare',
          'price',
          'amount',
          'ethb',
          'name',
          'phone',
          'route',
          'userid',
        ]) {
          expect(raw, isNot(contains(forbidden)),
              reason: 'QR must not leak "$forbidden"');
        }
      }
    });
  });

  group('QrCredential behaviour', () {
    final credential = QrCredential(
      ticketId: 'TKT-1',
      credentialId: 'CRD-1',
      issuedAt: 1790000000,
      expiresAt: 1790003600,
      nonce: 'abc123',
      keyId: 'k1',
      signature: 'sig==',
    );

    test('canonical payload uses the documented field order', () {
      expect(
        credential.canonicalPayload(),
        '1|TKT-1|CRD-1|1790000000|1790003600|abc123',
      );
    });

    test('expiry is evaluated against a supplied time', () {
      final before = DateTime.fromMillisecondsSinceEpoch(1790003600 * 1000);
      expect(credential.isExpiredAt(before), isFalse);

      final after = DateTime.fromMillisecondsSinceEpoch(1790003601 * 1000);
      expect(credential.isExpiredAt(after), isTrue);
    });

    test('tryParse returns null for malformed input rather than throwing', () {
      expect(QrCredential.tryParse('not json'), isNull);
      expect(QrCredential.tryParse('{}'), isNull);
      expect(QrCredential.tryParse('{"t":"TKT-1"}'), isNull);
      expect(QrCredential.tryParse(''), isNull);
    });

    test('tryParse rejects wrong field types', () {
      expect(
        QrCredential.tryParse(
          '{"t":"T","c":"C","i":"not-an-int","e":1,"n":"N","k":"k","s":"s"}',
        ),
        isNull,
      );
    });
  });
}
