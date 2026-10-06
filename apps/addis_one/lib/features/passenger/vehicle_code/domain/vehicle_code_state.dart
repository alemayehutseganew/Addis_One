import 'package:equatable/equatable.dart';

import '../../../../core/models/ticket.dart';
import '../../../../core/models/vehicle.dart';
import '../../journey_planner/domain/transport_repository.dart';

/// State of the "enter a vehicle code" flow.
///
/// A sealed union, for the same reason [PurchaseState] is one: an impossible
/// combination — say a ticket without a vehicle, or a found vehicle alongside a
/// payment failure — cannot be represented. The steps of the blueprint are
/// states, and the type system is what stops the UI from skipping one.
///
/// The critical boundary is the same as everywhere else in this app: only
/// [VehicleTicketIssued] carries a ticket. Nothing here can produce a QR from a
/// vehicle lookup, from a redirect, or from a timer.
sealed class VehicleCodeState extends Equatable {
  const VehicleCodeState();

  /// True while the app is talking to the server.
  ///
  /// Drives the disabled state of every button, so a second attempt cannot be
  /// launched while one is in flight.
  bool get isBusy =>
      this is VehicleLookingUp ||
      this is VehiclePaying ||
      this is VehicleAwaitingTicket;

  @override
  List<Object?> get props => [];
}

/// Nothing entered yet.
class VehicleCodeIdle extends VehicleCodeState {
  const VehicleCodeIdle();
}

/// Step 2: the code has been submitted and the system is being asked about it.
class VehicleLookingUp extends VehicleCodeState {
  const VehicleLookingUp(this.code);

  final String code;

  @override
  List<Object?> get props => [code];
}

/// Step 3, the NO branch: the code is not registered. Terminal — the flow stops
/// here and the passenger is told to check the code.
///
/// Distinct from [VehicleLookupFailure] on purpose. "No such vehicle" is a true
/// answer about the world and offers a Retry only in the sense of letting the
/// passenger retype; a network failure is an absence of an answer, and
/// pretending they are the same would tell a passenger standing at the wrong
/// bus that the server is down.
class VehicleNotFound extends VehicleCodeState {
  const VehicleNotFound(this.code);

  final String code;

  @override
  List<Object?> get props => [code];
}

/// Steps 4–5: the vehicle exists and its details are on screen awaiting
/// confirmation. No payment has been attempted and no idempotency key has been
/// burned.
class VehicleFound extends VehicleCodeState {
  const VehicleFound(this.vehicle);

  final VehicleProfile vehicle;

  @override
  List<Object?> get props => [vehicle];
}

/// The vehicle exists but cannot sell a ticket right now (maintenance,
/// out of service, retired, or quoted at zero fare).
///
/// Split from [VehicleNotFound] because the passenger's next action differs:
/// there is nothing to retype, and retrying immediately will fail identically.
class VehicleUnavailable extends VehicleCodeState {
  const VehicleUnavailable(this.vehicle, {required this.reason});

  final VehicleProfile vehicle;

  /// Server-supplied explanation, shown verbatim when present.
  final String? reason;

  @override
  List<Object?> get props => [vehicle, reason];
}

/// Steps 8–9: the payment was started and has not yet settled.
class VehiclePaying extends VehicleCodeState {
  const VehiclePaying({
    required this.paymentId,
    required this.reference,
    this.redirectUrl,
  });

  final String paymentId;
  final String reference;

  /// Set for providers that need the payer sent somewhere else. Reaching it is
  /// not payment.
  final String? redirectUrl;

  @override
  List<Object?> get props => [paymentId, reference, redirectUrl];
}

/// The payment is CONFIRMED; waiting for the backend to sign and return the
/// ticket. Assuming it succeeded here is exactly the bug I1 exists to prevent.
class VehicleAwaitingTicket extends VehicleCodeState {
  const VehicleAwaitingTicket(this.paymentId);

  final String paymentId;

  @override
  List<Object?> get props => [paymentId];
}

/// Steps 10–13: signed tickets exist for a confirmed payment.
///
/// Holds the whole group, not one ticket. A passenger who paid for four people
/// receives four independent credentials, each with its own signature and its
/// own single use — which is what makes forwarding them to friends and family
/// correct rather than a way to ride free on one fare.
///
/// **No passenger names are collected.** Nothing here, in the model, or in the
/// share payload identifies who is travelling: the QR is the ticket, and that is
/// deliberate. It matches invariant I4 — the credential carries identifiers
/// only — and it is why a forwarded ticket discloses nothing about who holds it.
class VehicleTicketsIssued extends VehicleCodeState {
  const VehicleTicketsIssued(
    this.tickets, {
    required this.vehicle,
    required this.quantityPaid,
  });

  /// One ticket per passenger. Never empty — a state carrying no ticket is not
  /// a success state.
  final List<IssuedTicket> tickets;

  /// Kept alongside so the QR screen can state which vehicle these are for
  /// without a second round trip.
  final VehicleProfile vehicle;

  /// How many fares were actually paid for.
  ///
  /// Compared against [tickets].length rather than assumed equal: a partial
  /// issuance is a real outcome the passenger must be told about, not an edge
  /// case to paper over.
  final int quantityPaid;

  /// True when fewer tickets came back than were paid for.
  ///
  /// The purchase succeeded — the money was taken and some tickets exist — but
  /// the passenger is short, and that is a dispute they need to know about
  /// before reaching the validator rather than after.
  bool get isShortIssued => tickets.length < quantityPaid;

  int get shortfall => quantityPaid - tickets.length;

  /// The ticket this passenger keeps for themselves.
  ///
  /// The first one, by issuance order. There is nothing to choose between them
  /// — they are interchangeable — so this is a convenience for showing one QR
  /// without making the payer hunt through a list.
  IssuedTicket get first => tickets.first;

  @override
  List<Object?> get props => [tickets, vehicle, quantityPaid];
}

/// Step 9, the NO branch: the payment did not succeed.
///
/// The vehicle is retained so Retry/Cancel can act on the same vehicle without
/// the passenger retyping and re-looking-up a code they already got right.
class VehiclePaymentFailed extends VehicleCodeState {
  const VehiclePaymentFailed({
    required this.failure,
    this.message,
    this.vehicle,
  });

  final ApiFailure failure;
  final String? message;
  final VehicleProfile? vehicle;

  /// Retry is offered only when the cause is one a retry can actually fix. A
  /// declined card or an invalid code will fail identically forever, so
  /// presenting "Retry" there would just invite a second charge attempt on a
  /// payment that was never going to succeed.
  bool get canRetry => failure.isRetryable;

  @override
  List<Object?> get props => [failure, message, vehicle];
}

/// The lookup itself failed (network, session, server). Retryable by nature.
class VehicleLookupFailure extends VehicleCodeState {
  const VehicleLookupFailure(this.failure, {this.message});

  final ApiFailure failure;
  final String? message;

  bool get canRetry => failure.isRetryable;

  @override
  List<Object?> get props => [failure, message];
}