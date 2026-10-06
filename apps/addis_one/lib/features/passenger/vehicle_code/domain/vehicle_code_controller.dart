import 'dart:async';
import 'dart:math';

import '../../../../core/models/journey.dart';
import '../../../../core/models/ticket.dart';
import '../../../../core/models/vehicle.dart';
import '../../journey_planner/domain/transport_repository.dart';
import 'vehicle_code_state.dart';
import 'vehicle_repository.dart';

/// Drives steps 2–13 of the vehicle-code flow.
///
/// **The rule this controller exists to enforce:** a QR is reachable only after
/// the backend reports the payment CONFIRMED *and* returns an issued ticket.
/// A successful lookup, a completed redirect, an elapsed timer, or a local
/// "it probably worked" can never produce [VehicleTicketIssued]. That is I1 on
/// the client, mirroring `PurchaseController` — and it matters more here, where
/// the passenger is standing at a vehicle with their phone already out.
///
/// The idempotency key is generated once, before the first payment attempt, and
/// reused for every retry of the *same* purchase, so a double-tap or a retry
/// after a dropped response converges on one charge rather than two (I2). It is
/// minted at payment time, not at lookup time: a lookup that is retried, or a
/// vehicle the passenger backs out of, must not consume a key.
class VehicleCodeController {
  VehicleCodeController({
    required VehicleRepository repository,
    this.pollInterval = const Duration(milliseconds: 1500),
    this.maxPollAttempts = 40,
    Random? random,
  })  : _repo = repository,
        _random = random ?? Random.secure();

  final VehicleRepository _repo;
  final Duration pollInterval;
  final int maxPollAttempts;
  final Random _random;

  VehicleCodeState _state = const VehicleCodeIdle();
  VehicleCodeState get state => _state;

  /// The key for the in-flight purchase. Null until [pay] is called.
  String? _activeIdempotencyKey;

  /// Records [next] as the current state and returns it.
  ///
  /// Returning the state is what lets every branch end with `return _emit(...)`
  /// instead of setting the state and then returning it separately. Two steps
  /// for one fact is how a branch ends up emitting one state and returning
  /// another, and the caller then acts on a state the controller is not in.
  VehicleCodeState _emit(VehicleCodeState next) {
    _state = next;
    return next;
  }

  /// Steps 1–3: normalises the code, looks it up, and lands on one of
  /// [VehicleNotFound], [VehicleFound], [VehicleUnavailable] or
  /// [VehicleLookupFailure].
  ///
  /// [rawCode] is upper-cased and trimmed first. A code pasted from a photo
  /// arrives with stray whitespace and lowercase, and an exact-match lookup
  /// would then report "Vehicle Not Found" for a vehicle that plainly exists —
  /// the most annoying possible failure for a passenger standing at the wrong
  /// door.
  Future<VehicleCodeState> lookup(String rawCode, {GeoPoint? boardingPoint}) async {
    final code = normalizeVehicleCode(rawCode);

    if (code.isEmpty) {
      return _emit(const VehicleLookupFailure(
        ApiFailure.validation,
        message: 'Enter a vehicle code',
      ));
    }

    _emit(VehicleLookingUp(code));

    try {
      // [boardingPoint] is forwarded, never used to price anything here. The
      // server decides which stop the passenger is at and what it costs; this
      // method only carries the coordinates so it can be asked for a quote. A
      // null point is normal — permission denied — and yields the flat fare.
      final vehicle = await _repo.lookupVehicle(code, boardingPoint: boardingPoint);

      // Null is a true answer, not an error: the code is simply not registered.
      if (vehicle == null) {
        return _emit(VehicleNotFound(code));
      }

      // A known vehicle that cannot sell a ticket is a distinct outcome. The
      // passenger is turned away by fleet state, not by a typo, so telling them
      // to check their code would send them to re-read one that was right.
      if (vehicle.status.isTemporarilyUnavailable ||
          vehicle.status == VehicleStatus.retired) {
        return _emit(VehicleUnavailable(vehicle, reason: null));
      }

      // A zero fare means the operator has not published one. Buying against it
      // would create a ticket the server cannot reconcile.
      if (!vehicle.fare.isPositive) {
        return _emit(VehicleUnavailable(
          vehicle,
          reason: 'No fare is published for this vehicle yet',
        ));
      }

      return _emit(VehicleFound(vehicle));
    } on ApiException catch (e) {
      return _emit(VehicleLookupFailure(e.failure, message: e.message));
    } catch (e) {
      return _emit(
        VehicleLookupFailure(ApiFailure.unknown, message: e.toString()),
      );
    }
  }
/// Steps 6–9: pays for [quantity] fares on [vehicle] and, only on a confirmed
  /// payment, collects the tickets issued for them.
  ///
  /// One payment, [quantity] tickets. This is the group case: one passenger pays
  /// for friends or family and forwards each QR on. Each ticket is an
  /// independent, single-use credential, so forwarding one does not let its
  /// recipient ride on someone else's fare — which is exactly what sharing a
  /// *single* QR would have done.
  ///
  /// [onRedirect] is handed the provider URL for providers that need the payer
  /// sent elsewhere. It is called *before* polling and its completion is not
  /// payment — `REQUIRES_ACTION` keeps the flow waiting.
  Future<VehicleCodeState> pay({
    required VehicleProfile vehicle,
    required PaymentMethod method,
    int quantity = 1,
    Future<void> Function(String url)? onRedirect,
  }) async {
    // Guarded rather than trusted: a quantity of zero would create a payment
    // for nothing and an empty ticket list, which is not a successful purchase.
    final count = quantity < 1 ? 1 : quantity;

    _activeIdempotencyKey ??= _generateKey();
    final key = _activeIdempotencyKey!;

    try {
      final started = await _repo.startVehiclePayment(
        vehicle: vehicle,
        // Exact integer arithmetic: 1500 fils x 3 is 4500, never 4499.99...
        amount: vehicle.fare * count,
        quantity: count,
        method: method,
        idempotencyKey: key,
      );

      _emit(VehiclePaying(
        paymentId: started.paymentId,
        reference: started.reference,
        redirectUrl: started.redirectUrl,
      ));

      final redirectUrl = started.redirectUrl;
      if (started.needsRedirect && onRedirect != null && redirectUrl != null) {
        await onRedirect(redirectUrl);
      }

      // The provider may have returned the tickets in the same response. Using
      // them saves a round trip, but only because they arrive alongside a
      // CONFIRMED status — never on their own.
      //
      // Held in a local so the null check promotes it; `started.ticket` is a
      // getter, and re-reading it after the check would leave the type
      // nullable at the call.
      final immediate = started.ticket;
      if (started.isComplete && immediate != null) {
        return _issued([immediate], vehicle, count);
      }

      final settled = await _awaitSettlement(started.paymentId);
      if (!settled) {
        return _failPayment(
          vehicle,
          ApiFailure.timeout,
          'Payment did not complete in time',
        );
      }

      _emit(VehicleAwaitingTicket(started.paymentId));

      final tickets = await _awaitTickets(started.paymentId);
      if (tickets.isEmpty) {
        return _failPayment(
          vehicle,
          ApiFailure.timeout,
          'No tickets were issued in time',
        );
      }

      return _issued(tickets, vehicle, count);
    } on ApiException catch (e) {
      return _failPayment(vehicle, e.failure, e.message);
    } catch (e) {
      return _failPayment(vehicle, ApiFailure.unknown, e.toString());
    }
  }

  VehicleCodeState _issued(
    List<IssuedTicket> tickets,
    VehicleProfile vehicle,
    int quantityPaid,
  ) {
    final next = VehicleTicketsIssued(
      tickets,
      vehicle: vehicle,
      quantityPaid: quantityPaid,
    );
    _emit(next);
    return next;
  }

  VehicleCodeState _failPayment(
    VehicleProfile vehicle,
    ApiFailure failure,
    String? message,
  ) {
    final next = VehiclePaymentFailed(
      failure: failure,
      message: message,
      vehicle: vehicle,
    );
    _emit(next);
    return next;
  }

  /// Polls until the payment is terminal.
  ///
  /// Returns true only for CONFIRMED. `REQUIRES_ACTION` and `PENDING` keep
  /// waiting — being sent to Telebirr is not having paid.
  Future<bool> _awaitSettlement(String paymentId) async {
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      final status = await _repo.vehiclePaymentStatus(paymentId);
      if (status.isConfirmed) return true;
      if (status.isTerminal) return false;
      await Future<void>.delayed(pollInterval);
    }
    return false;
  }

  /// Polls for the issued tickets.
  ///
  /// Empty means "not issued yet" — an expected intermediate state, so this is
  /// not an error. The signatures are verified server-side; the client only
  /// renders what it is given.
  ///
  /// Returns as soon as **any** ticket arrives rather than waiting for the full
  /// group. The shortfall, if any, is reported by the caller rather than being
  /// waited out indefinitely — a passenger standing at a vehicle is better
  /// served by three tickets and a visible warning than by a spinner.
  Future<List<IssuedTicket>> _awaitTickets(String paymentId) async {
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      final tickets = await _repo.ticketsForVehiclePayment(paymentId);
      if (tickets.isNotEmpty) return tickets;
      await Future<void>.delayed(pollInterval);
    }
    return const [];
  }

  /// Steps 14–16 from the passenger's side: re-read the ticket so it shows
  /// VALIDATED once a validator has scanned it.
  ///
  /// Returns the refreshed ticket, or null when the refresh is unavailable.
  /// Deliberately non-fatal — the passenger must still be able to show the QR
  /// they already hold, since a validator on a route with no signal may well
  /// have been the one to consume the connection.
  Future<IssuedTicket?> refresh(IssuedTicket ticket) async {
    try {
      final fresh = await _repo.refreshTicket(ticket.id);
      if (fresh == null) return null;

      final current = _state;
      if (current is VehicleTicketsIssued) {
        _emit(VehicleTicketsIssued(
          [fresh, ...current.tickets.where((t) => t.id != fresh.id)],
          vehicle: current.vehicle,
          quantityPaid: current.quantityPaid,
        ));
      }
      return fresh;
    } on ApiException {
      return null;
    }
  }

  /// 128 bits of randomness, hex encoded.
  String _generateKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Returns to idle and discards the idempotency key, so the *next* vehicle is
  /// treated as a new purchase rather than replaying the last one.
  void reset() {
    _activeIdempotencyKey = null;
    _emit(const VehicleCodeIdle());
  }

  bool get isInFlight => _state.isBusy;
}

/// Normalises what a passenger typed into the form the server indexes.
///
/// Upper-case, trimmed, and internal whitespace collapsed. Vehicle codes are
/// printed on the side of the vehicle in Amharic/English signage, so a code is
/// as likely to arrive from a screenshot as from the keyboard.
String normalizeVehicleCode(String raw) {
  return raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
}