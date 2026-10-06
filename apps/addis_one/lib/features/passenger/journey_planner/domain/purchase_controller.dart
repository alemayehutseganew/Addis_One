import 'dart:async';
import 'dart:math';

import '../../../../core/models/ticket.dart';
import '../../../../core/money.dart';
import '../domain/purchase_state.dart';
import '../domain/transport_repository.dart';

/// Drives the pay → confirm → issue flow.
///
/// **The rule this controller exists to enforce:** a ticket is shown only after
/// the backend reports the payment CONFIRMED and returns an issued ticket. A
/// redirect back from Telebirr, a local timer, or an optimistic UI update can
/// never produce [PurchaseSuccess].
///
/// The idempotency key is generated once, before the first attempt, and reused
/// for every retry of the *same* purchase. That is what makes a double-tap or a
/// network retry converge on one charge (I2) instead of two.
class PurchaseController {
  PurchaseController({
    required TransportRepository repository,
    this.pollInterval = const Duration(milliseconds: 1500),
    this.maxPollAttempts = 40,
    Random? random,
  })  : _repo = repository,
        _random = random ?? Random.secure();

  final TransportRepository _repo;
  final Duration pollInterval;
  final int maxPollAttempts;
  final Random _random;

  PurchaseState _state = const PurchaseIdle();
  PurchaseState get state => _state;

  Stream<PurchaseState> get states => Stream<PurchaseState>.value(_state);

  /// The key for the in-flight purchase. Null until [purchase] is called.
  String? _activeIdempotencyKey;

  /// Retrying after a failure MUST reuse the original key, otherwise the retry
  /// becomes a second payment.
  void _ensureIdempotencyKey() {
    _activeIdempotencyKey ??= _generateKey();
  }

  /// 128 bits of randomness, hex encoded.
  String _generateKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _emit(PurchaseState next) => _state = next;

  /// Runs the full purchase flow.
  ///
  /// Returns when the flow reaches a terminal state (success or failure).
  /// `onRedirect` lets the UI open a browser for providers that need it.
  Future<PurchaseState> purchase({
    required Money amount,
    required PaymentMethod method,
    String? journeyId,
    Future<void> Function(String url)? onRedirect,
  }) async {
    _ensureIdempotencyKey();
    final key = _activeIdempotencyKey!;

    try {
      _emit(const PurchaseCreatingPayment());

      final started = await _repo.startPayment(
        amount: amount,
        method: method,
        idempotencyKey: key,
        journeyId: journeyId,
      );

      _emit(PurchaseAwaitingPayment(
        paymentId: started.paymentId,
        reference: started.reference,
        status: started.status,
        redirectUrl: started.redirectUrl,
      ));

      if (started.needsRedirect && onRedirect != null) {
        await onRedirect(started.redirectUrl!);
      }

      // Poll until the backend settles the payment. Only CONFIRMED counts —
      // REQUIRES_ACTION and PENDING keep waiting.
      final settled = await _awaitSettlement(started.paymentId);
      if (!settled) {
        return _fail(
          const PurchaseAwaitingTicket('', ''),
          ApiFailure.timeout,
          'Payment did not complete in time',
        );
      }

      _emit(PurchaseAwaitingTicket(started.paymentId, started.reference));

      final ticket = await _awaitTicket(started.paymentId);
      if (ticket == null) {
        return _fail(
          PurchaseAwaitingTicket(started.paymentId, started.reference),
          ApiFailure.timeout,
          'Ticket was not issued in time',
        );
      }

      // A ticket that arrives non-usable is surfaced as-is rather than dressed
      // up as a success. The backend is the authority on validity.
      _emit(PurchaseSuccess(ticket));
      return _state;
    } on ApiException catch (e) {
      return _fail(_state, e.failure, e.message);
    } catch (e) {
      return _fail(_state, ApiFailure.unknown, e.toString());
    }
  }

  /// Polls payment status until it is terminal.
  ///
  /// Returns true only for CONFIRMED. A terminal failure returns false.
  Future<bool> _awaitSettlement(String paymentId) async {
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      final status = await _repo.paymentStatus(paymentId);

      if (status.isConfirmed) return true;
      if (status.isTerminal) return false; // failed / timeout / reversed

      await Future<void>.delayed(pollInterval);
    }
    return false;
  }

  /// Polls for the issued ticket.
  ///
  /// Null means "not issued yet" — an expected intermediate state, so this is
  /// not an error. The signature is verified server-side; the client only
  /// renders what it is given.
  Future<IssuedTicket?> _awaitTicket(String paymentId) async {
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      final ticket = await _repo.ticketForPayment(paymentId);
      if (ticket != null) return ticket;
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }

  PurchaseState _fail(PurchaseState from, ApiFailure failure, String? message) {
    final next = PurchaseFailure(failure, message: message);
    _emit(next);
    return next;
  }

  /// Returns to idle. The idempotency key is discarded so a *new* purchase is
  /// treated as a new payment.
  void reset() {
    _activeIdempotencyKey = null;
    _emit(const PurchaseIdle());
  }

  /// Whether [purchase] is currently running. Screens use this to prevent a
  /// second concurrent purchase attempt.
  bool get isInFlight => _state.isBusy;
}
