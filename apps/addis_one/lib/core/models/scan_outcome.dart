import 'package:equatable/equatable.dart';

/// The server's verdict on a scanned ticket.
///
/// Mirrors `ScanOutcome` in the Prisma schema. This is a wire vocabulary,
/// not a UI one: the server decides which value applies, and the app's job is to
/// present it faithfully. Re-deriving a verdict locally would violate the
/// architecture rule that the client renders server truth and never decides.
///
/// [unknown] exists only for a value this build has never seen. It is treated as
/// a refusal, because the safe reading of an outcome we cannot interpret is that
/// the passenger does not board.
enum ScanOutcome {
  valid,
  invalid,
  invalidSignature,
  expired,
  notYetValid,
  unknownCredential,
  notIssued,
  alreadyUsed,
  revoked,
  wrongTrip,
  wrongMode,
  unknown,
}

/// Parses the server's SCREAMING_SNAKE_CASE outcome string.
///
/// An unrecognised value becomes [ScanOutcome.unknown] rather than
/// throwing: a newer server adding an outcome must not crash an older handheld
/// in an inspector's hand at a bus door.
ScanOutcome parseScanOutcome(String? raw) {
  switch (raw) {
    case 'VALID':
      return ScanOutcome.valid;
    case 'INVALID':
      return ScanOutcome.invalid;
    case 'INVALID_SIGNATURE':
      return ScanOutcome.invalidSignature;
    case 'EXPIRED':
      return ScanOutcome.expired;
    case 'NOT_YET_VALID':
      return ScanOutcome.notYetValid;
    case 'UNKNOWN_CREDENTIAL':
      return ScanOutcome.unknownCredential;
    case 'NOT_ISSUED':
      return ScanOutcome.notIssued;
    case 'ALREADY_USED':
      return ScanOutcome.alreadyUsed;
    case 'REVOKED':
      return ScanOutcome.revoked;
    case 'WRONG_TRIP':
      return ScanOutcome.wrongTrip;
    case 'WRONG_MODE':
      return ScanOutcome.wrongMode;
    default:
      return ScanOutcome.unknown;
  }
}

/// Whether the officer should let this passenger board.
///
/// Derived from [outcome] rather than trusted from a separate `accepted` flag,
/// because the two are redundant and only one of them can be wrong. `accepted`
/// arrives on the wire and is kept on the model for the audit trail, but the UI
/// branches on this so a contradictory pair cannot produce a green screen on a
/// ticket the server refused.
bool outcomeAllowsBoarding(ScanOutcome outcome) =>
    outcome == ScanOutcome.valid;

/// Whether the officer should let this passenger board.
///
/// Defined on the enum itself rather than as an extension in the theme layer:
/// this is a property of the server's verdict, not a presentation choice, and it
/// is needed by tests and domain code that must not import any UI file. The
/// theme adds colour and icon on top of this, and derives from the same rule.
extension ScanOutcomeBoarding on ScanOutcome {
  bool get allowsBoarding => outcomeAllowsBoarding(this);
}

/// The result of one scan, as returned by `POST /validation/scan`.
class ScanResult extends Equatable {
  const ScanResult({
    required this.outcome,
    required this.accepted,
    required this.reason,
    required this.validatedAt,
    required this.validationReference,
    this.ticketReference,
  });

  factory ScanResult.fromJson(Map<String, dynamic> json) {
    final rawAccepted = json['accepted'];
    final outcome = parseScanOutcome(json['outcome'] as String?);
    return ScanResult(
      outcome: outcome,
      // A missing flag is not evidence of acceptance: fall back to the outcome
      // so an old server that omits the field cannot grant boarding by default.
      accepted: rawAccepted is bool ? rawAccepted : outcomeAllowsBoarding(outcome),
      reason: (json['reason'] as String?) ?? 'No reason supplied by the server.',
      validatedAt: DateTime.tryParse((json['validatedAt'] as String?) ?? '') ??
          DateTime.now(),
      validationReference:
          (json['validationReference'] as String?) ?? 'UNKNOWN',
      ticketReference: json['ticketReference'] as String?,
    );
  }

  final ScanOutcome outcome;

  /// The server's own accepted flag, preserved verbatim for the audit trail.
  final bool accepted;

  /// Human-readable explanation, written by the server for the officer on the
  /// spot. Shown as-is: a server that knows a ticket is a forgery can say so
  /// more precisely than any local string could.
  final String reason;

  final DateTime validatedAt;

  /// Reference of the recorded validation, or `UNRECORDED` when the write
  /// failed server-side. Not cosmetic — an officer may need to cite it.
  final String validationReference;

  /// Null for a forged or unknown credential, which has no ticket behind it.
  final String? ticketReference;

  bool get allowsBoarding => outcomeAllowsBoarding(outcome);

  /// True when the server recorded the attempt but could not persist it.
  ///
  /// The officer still gets a verdict, but the audit trail has a hole in it that
  /// somebody must reconcile, so it is surfaced rather than hidden.
  bool get isUnrecorded => validationReference == 'UNRECORDED';

  @override
  List<Object?> get props => [outcome, accepted, reason, validatedAt,
      validationReference, ticketReference];
}

/// One entry in the officer's own recent-scan history.
class ScanHistoryEntry extends Equatable {
  const ScanHistoryEntry({
    required this.outcome,
    required this.validatedAt,
    required this.reference,
    this.ticketReference,
    this.ticketMode,
    this.reasonDetail,
  });

  factory ScanHistoryEntry.fromJson(Map<String, dynamic> json) {
    final ticket = json['ticket'];
    return ScanHistoryEntry(
      outcome: parseScanOutcome(json['outcome'] as String?),
      validatedAt: DateTime.tryParse((json['validatedAt'] as String?) ?? '') ??
          DateTime.now(),
      reference: (json['reference'] as String?) ?? 'UNKNOWN',
      ticketReference: ticket is Map ? ticket['reference'] as String? : null,
      ticketMode: ticket is Map ? ticket['mode'] as String? : null,
      reasonDetail: json['reasonDetail'] as String?,
    );
  }

  final ScanOutcome outcome;
  final DateTime validatedAt;
  final String reference;
  final String? ticketReference;
  final String? ticketMode;
  final String? reasonDetail;

  bool get allowsBoarding => outcomeAllowsBoarding(outcome);

  @override
  List<Object?> get props =>
      [outcome, validatedAt, reference, ticketReference, ticketMode, reasonDetail];
}
