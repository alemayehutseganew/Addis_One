import '../../../../core/models/scan_outcome.dart';
import '../../../../core/network/api_failure.dart';
import '../../auth/domain/staff_repository.dart';
import 'scan_queue.dart';

/// A scan outcome plus how it was obtained.
///
/// The distinction matters to the officer: a live scan carries a server verdict,
/// while a deferred one carries no verdict at all. Collapsing them would let a
/// queued ticket be read as a clearance that never happened.
class ScanSubmission {
  const ScanSubmission({required this.result, required this.isDeferred});

  final ScanResult result;

  /// True when the server was unreachable and the ticket was parked locally.
  final bool isDeferred;
}

/// Submits scans to the server, parking them locally when it cannot be reached.
class ScanSubmitter {
  ScanSubmitter({
    // ignore: prefer_initializing_formals
    required StaffRepository repo,
    // ignore: prefer_initializing_formals
    required ScanQueue queue,
  })  :
        // ignore: prefer_initializing_formals
        _repo = repo,
        // ignore: prefer_initializing_formals
        _queue = queue;

  final StaffRepository _repo;
  final ScanQueue _queue;

  Future<ScanSubmission> submit(String qrString) async {
    try {
      final result = await _repo.scan(qrString);
      return ScanSubmission(result: result, isDeferred: false);
    } on ApiException catch (e) {
      if (!e.isRetryable) rethrow;

      // Only transient failures are queued. A refusal from the server is a real
      // verdict and must be shown, never parked for later.
      await _queue.add(qrString);

      return ScanSubmission(
        result: ScanResult(
          outcome: ScanOutcome.unknown,
          accepted: false,
          reason:
              'No connection to the server. This ticket was recorded on the '
              'handheld and will be validated when the network returns.',
          validatedAt: DateTime.now(),
          validationReference: 'PENDING',
        ),
        isDeferred: true,
      );
    }
  }

  Future<QueueDrainResult> drainPending() => _queue.drain(_repo);

  Future<int> get pendingCount => _queue.pendingCount;

  Future<void> discardPending() => _queue.clear();
}
