import 'package:equatable/equatable.dart';

import '../money.dart';
import 'qr_credential.dart';
import 'ticket_validation.dart';

/// Ticket lifecycle, mirroring the backend `TicketStatus`.
///
/// The client mirrors the backend state machine rather than inventing its own
/// idea of "paid" or "valid". Two reasons: the passenger must be told the truth,
/// and a client that second-guesses the server is how a cancelled ticket ends
/// up looking usable at the gate.
enum TicketStatus {
  created('CREATED'),
  fareQuoted('FARE_QUOTED'),
  paymentPending('PAYMENT_PENDING'),
  paymentAuthorized('PAYMENT_AUTHORIZED'),
  paymentConfirmed('PAYMENT_CONFIRMED'),
  ticketIssued('TICKET_ISSUED'),
  valid('VALID'),
  validated('VALIDATED'),
  completed('COMPLETED'),
  paymentFailed('PAYMENT_FAILED'),
  paymentTimeout('PAYMENT_TIMEOUT'),
  paymentReversed('PAYMENT_REVERSED'),
  refunded('REFUNDED'),
  expired('EXPIRED'),
  cancelled('CANCELLED'),
  voided('VOIDED');

  const TicketStatus(this.wire);
  final String wire;

  /// True once the backend has issued a credential.
  bool get isIssued =>
      this == TicketStatus.ticketIssued ||
      this == TicketStatus.valid ||
      this == TicketStatus.validated ||
      this == TicketStatus.completed;

  /// True when the ticket can still be presented to an inspector.
  bool get isUsable => this == TicketStatus.valid;

  /// Terminal states never change again.
  bool get isTerminal =>
      this == TicketStatus.completed ||
      this == TicketStatus.paymentFailed ||
      this == TicketStatus.paymentTimeout ||
      this == TicketStatus.paymentReversed ||
      this == TicketStatus.refunded ||
      this == TicketStatus.expired ||
      this == TicketStatus.cancelled ||
      this == TicketStatus.voided;

  /// A failure the passenger should be shown with an action attached.
  bool get isFailure =>
      this == TicketStatus.paymentFailed ||
      this == TicketStatus.paymentTimeout ||
      this == TicketStatus.paymentReversed;

  static TicketStatus fromWire(String? value) {
    return TicketStatus.values.firstWhere(
      (s) => s.wire == value,
      orElse: () => TicketStatus.created,
    );
  }
}

/// Payment states, mirroring the backend `PaymentStatus`.
enum PaymentStatus {
  created('CREATED'),
  pending('PENDING'),
  requiresAction('REQUIRES_ACTION'),
  authorized('AUTHORIZED'),
  confirmed('CONFIRMED'),
  failed('FAILED'),
  timeout('TIMEOUT'),
  reversed('REVERSED'),
  refunded('REFUNDED'),
  partiallyRefunded('PARTIALLY_REFUNDED');

  const PaymentStatus(this.wire);
  final String wire;

  /// **This is the only state that unlocks ticket issuance (I1).**
  ///
  /// `requiresAction` deliberately does not qualify: it means the payer was
  /// sent somewhere to pay, which is not the same as having paid.
  bool get isConfirmed => this == PaymentStatus.confirmed;

  bool get isTerminal =>
      this == PaymentStatus.confirmed ||
      this == PaymentStatus.failed ||
      this == PaymentStatus.timeout ||
      this == PaymentStatus.reversed ||
      this == PaymentStatus.refunded ||
      this == PaymentStatus.partiallyRefunded;

  /// A state where the payer may still need to act.
  bool get isActionable =>
      this == PaymentStatus.requiresAction || this == PaymentStatus.pending;

  static PaymentStatus fromWire(String? value) {
    return PaymentStatus.values.firstWhere(
      (s) => s.wire == value,
      orElse: () => PaymentStatus.created,
    );
  }
}

/// Payment methods offered at launch.
enum PaymentMethod {
  telebirr('TELEBIRR', 'Telebirr'),
  cbeBirr('CBE_BIRR', 'CBE Birr'),
  bank('BANK', 'Bank'),
  wallet('WALLET', 'Wallet');

  const PaymentMethod(this.wire, this.label);
  final String wire;
  final String label;

  static PaymentMethod fromWire(String? value) {
    return PaymentMethod.values.firstWhere(
      (m) => m.wire == value,
      orElse: () => PaymentMethod.telebirr,
    );
  }
}

/// An issued ticket as returned by the backend.
class IssuedTicket extends Equatable {
  const IssuedTicket({
    required this.id,
    required this.reference,
    required this.status,
    required this.issuedAt,
    required this.expiresAt,
    this.fare = Money.zero,
    this.credential,
    this.mode,
    this.tripId,
    this.fareRuleVersion,
    this.providerMode,
    this.entryValidation,
    this.exitValidation,
  });

  final String id;
  final String reference;
  final TicketStatus status;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final Money fare;

  /// Present only once the backend has issued and signed a credential.
  /// Until then there is nothing to display as a QR code.
  final QrCredential? credential;
  final String? mode;
  final String? tripId;

  /// I3: the fare rule version this ticket was priced against. Null means the
  /// fare engine found no matching rule, which is worth surfacing — such a
  /// ticket was priced by a fallback and should be reconciled.
  final int? fareRuleVersion;

  /// "MOCK" while the payment provider is the development stub.
  ///
  /// Carried onto the ticket so the UI can say plainly that this was not a real
  /// money movement, rather than implying a live payment succeeded.
  final String? providerMode;

  /// True when this ticket was bought through a simulated provider.
  bool get isSimulatedPayment => providerMode == 'MOCK';

  /// The boarding scan, or null while the passenger has not been admitted.
  final TicketValidationRecord? entryValidation;

  /// The alighting scan, or null while the ride is still open.
  ///
  /// Null with a non-null [entryValidation] is the normal mid-journey state and
  /// means nothing is wrong.
  final TicketValidationRecord? exitValidation;

  /// Where the ride has got to. Derived from the two scans rather than stored,
  /// so it cannot drift out of step with them.
  JourneyStage get journeyStage => resolveStage(
        entry: entryValidation,
        exit: exitValidation,
      );

  /// True once both scans are in: the ticket is fully spent.
  bool get isFullyUsed => journeyStage == JourneyStage.alighted;

  /// Whether a scan of [kind] would currently be permitted.
  ///
  /// Lets the UI explain a refusal before the passenger reaches a gate. The
  /// server remains the authority on this — see [canScan].
  bool permits(ValidationKind kind) => canScan(
        kind,
        entry: entryValidation,
        exit: exitValidation,
      );

  bool get hasQr => credential != null;

  bool isExpiredAt(DateTime now) => now.isAfter(expiresAt);

  /// A ticket the passenger can actually board with right now.
  ///
  /// Requires all three: backend says usable, a QR exists, and it has not
  /// expired. Checking only the status is how an expired ticket keeps
  /// displaying as valid.
  bool isBoardableAt(DateTime now) =>
      status.isUsable && hasQr && !isExpiredAt(now);

  /// Parses the ticket shape the API returns.
  ///
  /// The backend sends the credential as a single `qrString` (the exact bytes to
  /// render) rather than as structured fields. It is parsed here so the rest of
  /// the app works with typed values, and so a malformed credential shows up as
  /// "no QR" instead of a crash on a passenger standing at a bus stop.
  static IssuedTicket fromJson(Map<String, dynamic> json) {
    final credential = QrCredential.tryParse(json['qrString'] as String? ?? '');

    // Entry and exit arrive as a list of scans on the append-only ledger. The
    // LAST record of each kind wins: the ledger never rewrites history, so the
    // most recent scan is the live one.
    final validations = _validationsFrom(json);

    return IssuedTicket(
      // The API names this `ticketId` on the payment-scoped endpoint and `id`
      // on /tickets/mine; accept either so both shapes work.
      id: json['id'] as String? ?? json['ticketId'] as String? ?? '',
      reference: json['reference'] as String? ?? '',
      status: TicketStatus.fromWire(json['status'] as String?),
      issuedAt: _date(json['issuedAt']) ?? DateTime.now(),
      expiresAt: _date(json['expiresAt']) ?? DateTime.now(),
      fare: Money(json['fareFils'] as int? ?? 0),
      credential: credential,
      mode: json['mode'] as String?,
      tripId: json['tripId'] as String?,
      // I3: the fare rule version pinned at issuance. Surfaced so a passenger
      // disputing a charge can be shown which policy priced it.
      fareRuleVersion: json['fareRuleVersion'] as int?,
      providerMode: json['providerMode'] as String?,
      entryValidation: validations.entry,
      exitValidation: validations.exit,
    );
  }

  /// Pulls the entry and exit scans out of whatever shape the API used.
  ///
  /// Accepts `validations` (the append-only ledger), or the flattened
  /// `entryValidation` / `exitValidation` pair. A server that sends neither
  /// simply has no scans yet, which is the normal state of a fresh ticket —
  /// never an error.
  static ({TicketValidationRecord? entry, TicketValidationRecord? exit})
      _validationsFrom(Map<String, dynamic> json) {
    final list = json['validations'] as List?;
    if (list != null) {
      TicketValidationRecord? entry;
      TicketValidationRecord? exit;
      for (final row in list.cast<Map<String, dynamic>>()) {
        final record = TicketValidationRecord.fromJson(row);
        if (record == null) continue;
        if (record.kind == ValidationKind.entry) {
          entry = record;
        } else {
          exit = record;
        }
      }
      return (entry: entry, exit: exit);
    }

    final flatEntry = json['entryValidation'] as Map<String, dynamic>?;
    final flatExit = json['exitValidation'] as Map<String, dynamic>?;
    return (
      entry: flatEntry == null ? null : TicketValidationRecord.fromJson(flatEntry),
      exit: flatExit == null ? null : TicketValidationRecord.fromJson(flatExit),
    );
  }

  static DateTime? _date(Object? value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.toLocal();
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    return null;
  }

  @override
  List<Object?> get props => [
        id,
        reference,
        status,
        issuedAt,
        expiresAt,
        fare,
        credential,
        mode,
        tripId,
        fareRuleVersion,
        providerMode,
        entryValidation,
        exitValidation,
      ];
}

/// The result of starting a payment.
///
/// Carries the redirect URL and, critically, the payment status. The app must
/// never treat a redirect as confirmation — see [PaymentStatus.isConfirmed].
class PaymentStartResult extends Equatable {
  const PaymentStartResult({
    required this.paymentId,
    required this.reference,
    required this.status,
    this.redirectUrl,
    this.ticket,
  });

  final String paymentId;

  /// Human-facing reference. The API sends `paymentReference`.
  final String reference;
  final PaymentStatus status;
  final String? redirectUrl;

  /// Present only when the provider CONFIRMED and a ticket was issued in the
  /// same request. Null while the payment is merely PENDING or REQUIRES_ACTION —
  /// which is the whole point of I1: reaching the payment screen is not paying.
  final IssuedTicket? ticket;

  /// True when the payer must be sent to the provider before payment settles.
  bool get needsRedirect => redirectUrl != null && status.isActionable;

  /// True when this purchase is finished and a ticket is in hand.
  bool get isComplete => status.isConfirmed && ticket != null;

  static PaymentStartResult fromJson(Map<String, dynamic> json) {
    final ticketJson = json['ticket'] as Map<String, dynamic>?;
    return PaymentStartResult(
      paymentId: json['paymentId'] as String? ?? json['id'] as String? ?? '',
      reference: json['paymentReference'] as String? ??
          json['reference'] as String? ??
          '',
      status: PaymentStatus.fromWire(json['status'] as String?),
      redirectUrl: json['redirectUrl'] as String?,
      ticket: ticketJson == null
          ? null
          : IssuedTicket.fromJson({
              ...ticketJson,
              // Carry the provider mode onto the ticket so the QR screen can
              // state plainly that no real money moved.
              'providerMode': json['providerMode'],
            }),
    );
  }

  @override
  List<Object?> get props =>
      [paymentId, reference, status, redirectUrl, ticket];
}
