import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/network/api_failure.dart';
import '../../auth/domain/staff_repository.dart';

/// A scan taken while the server could not be reached.
class QueuedScan {
  const QueuedScan({
    required this.qrString,
    required this.queuedAt,
    required this.attempts,
  });

  factory QueuedScan.fromJson(Map<String, dynamic> json) => QueuedScan(
        qrString: json['qrString'] as String,
        queuedAt: DateTime.parse(json['queuedAt'] as String),
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      );

  final String qrString;
  final DateTime queuedAt;
  final int attempts;

  Map<String, dynamic> toMap() => {
        'qrString': qrString,
        'queuedAt': queuedAt.toIso8601String(),
        'attempts': attempts,
      };
}

/// What happened to the queue when it was drained.
class QueueDrainResult {
  const QueueDrainResult({
    required this.delivered,
    required this.discarded,
    this.lastError,
  });

  final int delivered;

  /// Entries dropped without a verdict — see [_isPermanent] for why.
  final int discarded;

  final String? lastError;

  bool get isEmpty => delivered == 0 && discarded == 0;
}

/// Holds scans taken out of coverage and delivers them when the server returns.
///
/// ## Why this exists at all
///
/// An inspector works a door, not an office. Between stops there is frequently
/// no usable signal, and "the scanner said nothing" is not an answer an officer
/// can give a passenger.
///
/// ## What it deliberately does NOT do
///
/// A queued scan is **not** shown to the officer as VALID. That would be the
/// single most dangerous thing this app could do: an offline device would wave
/// through anyone, and the server — the only authority — would find out later.
/// The queue records that a ticket was *presented*, and nothing more. The
/// verdict arrives when the server is reachable, or never.
///
/// This follows the architecture rule that the client renders server truth and
/// may be offline only in a strictly constrained, later-reconciled way.
class ScanQueue {
  ScanQueue({
    // ignore: prefer_initializing_formals
    SharedPreferences? prefs,
  })  :
        // ignore: prefer_initializing_formals
        _prefs = prefs;

  static const _key = 'addis_one_staff_pending_scans';
  static const _maxEntries = 200;

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Reads the pending queue, oldest first so it drains in the order scanned.
  Future<List<QueuedScan>> pending() async {
    final store = await _store;
    final raw = store.getStringList(_key) ?? const <String>[];
    final out = <QueuedScan>[];
    for (final entry in raw) {
      try {
        out.add(QueuedScan.fromJson(
          jsonDecode(entry) as Map<String, dynamic>,
        ));
      } catch (_) {
        // A corrupt entry is skipped rather than allowed to abort the whole
        // queue: one unreadable record must not strand every later scan too.
      }
    }
    return out;
  }

  Future<int> get pendingCount async => (await pending()).length;

  /// Adds a scan to the queue.
  ///
  /// Silently drops the oldest entry when [maxEntries] is reached. Unbounded
  /// growth on a device with no connectivity for a whole shift would eventually
  /// exhaust storage and take the app down mid-service, which is worse than
  /// losing the oldest scans.
  Future<void> add(String qrString) async {
    final store = await _store;
    final current = store.getStringList(_key) ?? <String>[];
    current.add(jsonEncode(QueuedScan(
      qrString: qrString,
      queuedAt: DateTime.now(),
      attempts: 0,
    ).toMap()));
    final trimmed = current.length > _maxEntries
        ? current.sublist(current.length - _maxEntries)
        : current;
    await store.setStringList(_key, trimmed);
  }

/// Attempts delivery of every queued scan, oldest first.
  ///
  /// Stops at the first entry that cannot be delivered rather than continuing,
  /// because the queue is ordered by time and later scans were taken against a
  /// system that had not yet seen the earlier ones. Reordering validation would
  /// change which scan is legitimately first.
  Future<QueueDrainResult> drain(StaffRepository repo) async {
    final queued = await pending();
    if (queued.isEmpty) {
      return const QueueDrainResult(delivered: 0, discarded: 0);
    }

    var delivered = 0;
    var discarded = 0;
    String? lastError;

    for (final scan in queued) {
      try {
        await repo.scan(scan.qrString);
        delivered++;
        await _remove(qrString: scan.qrString);
      } on ApiException catch (e) {
        lastError = e.message ?? e.failure.name;
        if (_isPermanent(e)) {
          // The server will never accept this — an expired session, or a role
          // that cannot scan. Keeping it would replay a guaranteed failure on
          // every future reconnect, which is how an offline queue becomes a
          // permanent backlog nobody can clear.
          discarded++;
          await _remove(qrString: scan.qrString);
          continue;
        }
        // Transient. Stop here and keep order intact; the rest stay queued.
        break;
      }
    }

    return QueueDrainResult(
      delivered: delivered,
      discarded: discarded,
      lastError: lastError,
    );
  }

  /// Whether a failure will recur identically on retry.
  ///
  /// A queued entry that can never succeed is worse than a lost one: it is
  /// invisible in the UI and replays forever.
  static bool _isPermanent(ApiException e) {
    switch (e.failure) {
      case ApiFailure.unauthorized:
      case ApiFailure.validation:
      case ApiFailure.notFound:
        return true;
      case ApiFailure.network:
      case ApiFailure.server:
      case ApiFailure.timeout:
      case ApiFailure.unknown:
      case ApiFailure.cancelled:
      case ApiFailure.offline:
        return false;
    }
  }

  /// Removes one entry.
  ///
  /// Matches on the QR string rather than an index: the list is re-read on every
  /// mutation, so an index captured before an await would address the wrong
  /// entry once another write landed.
  Future<void> _remove({required String qrString}) async {
    final store = await _store;
    final current = store.getStringList(_key) ?? <String>[];
    final remaining = current.where((e) {
      try {
        return (jsonDecode(e) as Map)['qrString'] != qrString;
      } catch (_) {
        return false;
      }
    }).toList();
    await store.setStringList(_key, remaining);
  }

  /// Discards everything.
  ///
  /// Offered explicitly rather than silently, because these scans are evidence
  /// that tickets were presented; discarding them without saying so could hide a
  /// pattern of scanning attempts during a later dispute.
  Future<void> clear() async {
    final store = await _store;
    await store.remove(_key);
  }
}
