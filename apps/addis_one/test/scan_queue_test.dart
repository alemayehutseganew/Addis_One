// Regression tests for the offline scan queue.
//
// This is the part of the app that is hardest to review and easiest to get
// quietly wrong, because it decides what happens to a ticket an officer scanned
// with no signal, on a device nobody is watching. Two mistakes here are revenue
// incidents rather than bugs:
//
//   1. Presenting a parked scan as a clearance. An offline handheld that waves
//      anyone through is the single worst failure this app could have, and it is
//      invisible to the server until much later.
//   2. Keeping an entry the server will never accept. It replays on every
//      reconnect, forever, invisibly.
//
// Both are pinned below, along with the ordering and storage behaviour the
// comments in scan_queue.dart promise but nothing was checking.
import 'dart:convert';

import 'package:addis_one/core/models/scan_outcome.dart';
import 'package:addis_one/core/network/api_failure.dart';
import 'package:addis_one/features/staff/auth/domain/staff_repository.dart';
import 'package:addis_one/features/staff/validation/data/scan_queue.dart';
import 'package:addis_one/features/staff/validation/data/scan_submitter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The private key ScanQueue persists under.
///
/// Duplicated as a literal because the field is private, and reaching it with a
/// debugger would defeat the purpose of these tests: seeding the store directly
/// is how corrupt and over-full states get constructed, and neither can be
/// produced through the public API without hundreds of round trips.
const _queueKey = 'addis_one_staff_pending_scans';

/// A repository whose `scan` answers from a caller-supplied script.
///
/// Every other member throws, so a queue that starts calling something else is a
/// test failure rather than a silently-passing extra call.
class _ScriptedRepo implements StaffRepository {
  _ScriptedRepo(this._onScan);

  final Future<ScanResult> Function(String qrString) _onScan;

  /// Every QR string passed to [scan], in order.
  final attempts = <String>[];

  @override
  Future<ScanResult> scan(String qrString) async {
    attempts.add(qrString);
    return _onScan(qrString);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the queue must not call ${invocation.memberName}');
}

/// A repository that fails every scan with [failure].
///
/// [statusCode] is carried because the queue's permanent/transient decision is
/// made on [ApiFailure] alone — the test states both so that a future change to
/// the mapping is visible here rather than silently reclassifying these cases.
_ScriptedRepo _alwaysFails(
  ApiFailure failure, {
  String? message,
  int? statusCode,
}) =>
    _ScriptedRepo(
      (_) async => throw ApiException(
        failure,
        message: message,
        statusCode: statusCode,
      ),
    );

/// A repository that accepts every scan.
_ScriptedRepo _alwaysAccepts() => _ScriptedRepo((_) async => _validResult());

ScanResult _validResult() => ScanResult(
      outcome: ScanOutcome.valid,
      accepted: true,
      reason: 'Ticket is valid for boarding.',
      validatedAt: DateTime.utc(2026, 10, 4),
      validationReference: 'VAL-1',
    );

String _entry(String qrString) => jsonEncode(
      QueuedScan(
        qrString: qrString,
        queuedAt: DateTime.utc(2026, 10, 4),
        attempts: 0,
      ).toMap(),
    );

void main() {
  // A fresh store per test. Without this the singleton survives between tests and
  // a queue left full by one test silently becomes another test's input.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ScanQueue> freshQueue() async =>
      ScanQueue(prefs: await SharedPreferences.getInstance());

  group('ScanSubmitter decides what is worth keeping', () {
    test('an unreachable server is parked and never called a clearance',
        () async {
      final submitter = ScanSubmitter(
        repo: _alwaysFails(ApiFailure.network),
        queue: await freshQueue(),
      );

      final submission = await submitter.submit('QR-1');

      expect(submission.isDeferred, isTrue);
      // The invariant the whole queue exists to protect. Every other assertion
      // here is cosmetic; this one is the revenue guarantee.
      expect(submission.result.allowsBoarding, isFalse);
      expect(submission.result.accepted, isFalse);
      expect(submission.result.outcome, ScanOutcome.unknown);
      expect(submission.result.validationReference, 'PENDING');
      expect(await submitter.pendingCount, 1);
    });

    test('a role refusal is shown to the officer, never parked', () async {
      // 403 maps to `unauthorized`, which is not retryable. A refusal is a real
      // verdict about this ticket: parking it would tell the officer "no
      // connection, we'll check later" about a ticket the server has already
      // rejected, which is a materially different thing to say to a passenger.
      final queue = await freshQueue();
      final submitter = ScanSubmitter(
        repo: _alwaysFails(ApiFailure.unauthorized, statusCode: 403),
        queue: queue,
      );

      await expectLater(
        submitter.submit('QR-1'),
        throwsA(isA<ApiException>()),
      );
      expect(await submitter.pendingCount, 0);
    });

    test('a server fault is parked because the server may recover', () async {
      // The counterpart to the 403 above: 5xx says nothing about the ticket, so
      // this is the case where parking is exactly right.
      final submitter = ScanSubmitter(
        repo: _alwaysFails(ApiFailure.server, statusCode: 503),
        queue: await freshQueue(),
      );

      final submission = await submitter.submit('QR-1');

      expect(submission.isDeferred, isTrue);
      expect(await submitter.pendingCount, 1);
    });

    test('a live scan carries the server verdict, not a deferred one', () async {
      final submitter = ScanSubmitter(
        repo: _alwaysAccepts(),
        queue: await freshQueue(),
      );

      final submission = await submitter.submit('QR-1');

      expect(submission.isDeferred, isFalse);
      expect(submission.result.outcome, ScanOutcome.valid);
      expect(submission.result.validationReference, 'VAL-1');
      expect(await submitter.pendingCount, 0);
    });
  });

  group('ScanQueue delivers in scan order', () {
    test('drains oldest first and empties itself', () async {
      final queue = await freshQueue();
      await queue.add('QR-1');
      await queue.add('QR-2');
      await queue.add('QR-3');
      final repo = _alwaysAccepts();

      final result = await queue.drain(repo);

      expect(repo.attempts, ['QR-1', 'QR-2', 'QR-3']);
      expect(result.delivered, 3);
      expect(result.discarded, 0);
      expect(await queue.pendingCount, 0);
    });

    test('stops at the first transient failure and keeps the rest queued',
        () async {
      // Order is the point: these tickets were taken against a system that had
      // not yet seen the earlier ones, so delivering QR-3 past a failed QR-2
      // would let a replayed ticket validate before its first scan.
      final queue = await freshQueue();
      await queue.add('QR-1');
      await queue.add('QR-2');
      await queue.add('QR-3');
      final repo = _ScriptedRepo((qr) async {
        if (qr == 'QR-2') throw const ApiException(ApiFailure.network);
        return _validResult();
      });

      final result = await queue.drain(repo);

      expect(repo.attempts, ['QR-1', 'QR-2']);
      expect(result.delivered, 1);
      expect(result.discarded, 0);
      expect(result.lastError, isNotNull);
      expect(await queue.pendingCount, 2);
    });

    test('discards an entry the server will never accept and carries on',
        () async {
      final queue = await freshQueue();
      await queue.add('QR-1');
      await queue.add('QR-2');
      final repo = _ScriptedRepo((qr) async {
        if (qr == 'QR-1') {
          throw const ApiException(
            ApiFailure.unauthorized,
            message: 'Your role cannot scan.',
            statusCode: 403,
          );
        }
        return _validResult();
      });

      final result = await queue.drain(repo);

      // Unlike the transient case this does NOT stop the drain — a doomed entry
      // cannot reorder anything, so it must not block the scans behind it.
      expect(repo.attempts, ['QR-1', 'QR-2']);
      expect(result.delivered, 1);
      expect(result.discarded, 1);
      expect(result.lastError, 'Your role cannot scan.');
      expect(await queue.pendingCount, 0);
    });

    test('an expired session does not become a permanent backlog', () async {
      // Deliberate data loss, pinned on purpose. Once the session has expired
      // every retry of this entry fails identically, so keeping it would replay
      // the failure on every reconnect and block the queue behind it forever.
      // A visibly failed scan is better than a backlog that silently never
      // drains — but that is a trade-off, not an inevitability, so it is
      // asserted here rather than left to chance.
      final queue = await freshQueue();
      await queue.add('QR-1');
      final repo = _alwaysFails(ApiFailure.unauthorized, statusCode: 401);

      final result = await queue.drain(repo);

      expect(result.discarded, 1);
      expect(result.delivered, 0);
      expect(await queue.pendingCount, 0);
    });

    test('an empty queue drains without touching the server', () async {
      final queue = await freshQueue();
      final repo = _ScriptedRepo((_) async => throw StateError('no calls'));

      final result = await queue.drain(repo);

      expect(result.isEmpty, isTrue);
      expect(repo.attempts, isEmpty);
    });
  });

  group('ScanQueue survives a bad store', () {
    test('skips a corrupt entry instead of stranding every later scan',
        () async {
      final queue = await freshQueue();
      final store = await SharedPreferences.getInstance();
      await store.setStringList(_queueKey, [
        '{not json at all',
        _entry('QR-2'),
        'also not json',
        _entry('QR-3'),
      ]);
      expect(await queue.pendingCount, 2);

      final repo = _alwaysAccepts();
      final result = await queue.drain(repo);

      // The corrupt entries are skipped, not delivered — the server is never
      // asked to validate a string that was never a ticket.
      expect(repo.attempts, ['QR-2', 'QR-3']);
      expect(result.delivered, 2);
      expect(await queue.pendingCount, 0);
    });

    test('caps the queue by dropping the oldest entries', () async {
      // Unbounded growth on a device with no signal for a whole shift would
      // eventually exhaust storage and take the app down mid-service.
      final queue = await freshQueue();
      final store = await SharedPreferences.getInstance();
      await store.setStringList(
        _queueKey,
        List<String>.generate(200, (i) => _entry('QR-$i')),
      );

      await queue.add('QR-new');

      final pending = await queue.pending();
      expect(pending.length, 200);
      // QR-0 was the oldest and is the one sacrificed.
      expect(pending.first.qrString, 'QR-1');
      expect(pending.last.qrString, 'QR-new');
    });
  });
}
