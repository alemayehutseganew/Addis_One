import 'package:equatable/equatable.dart';

/// Which end of the journey a scan records.
///
/// A ticket is scanned **twice**, not once — boarding and alighting. This is the
/// difference between a flat "mark as used" flag and a real entry/exit ledger,
/// and it matters for three reasons:
///
///  1. It is what makes an open-ended bus fare enforceable. The exit scan is
///     what proves the ride finished; without it there is no bound on how far
///     a ticket travelled.
///  2. It produces two timestamps, so a dispute is settled against facts
///     rather than against "the driver says he scanned it".
///  3. The pairing is what enforces single use. A second ENTRY on the same
///     ticket is a duplicate and is refused — precisely the control a flat
///     boolean cannot express.
enum ValidationKind {
  entry('ENTRY'),
  exit('EXIT');

  const ValidationKind(this.wire);
  final String wire;

  /// The scan that comes next, given this one was the last recorded.
  ValidationKind get counterpart =>
      this == ValidationKind.entry ? ValidationKind.exit : ValidationKind.entry;

  static ValidationKind fromWire(String? value) {
    return ValidationKind.values.firstWhere(
      (k) => k.wire == value,
      orElse: () => ValidationKind.entry,
    );
  }
}

/// Where a ticket sits in its entry/exit lifecycle.
///
/// Distinct from `TicketStatus`, which is the backend's coarse lifecycle
/// (issued → valid → …). This is the narrower question of whether the *ride*
/// has started and finished.
enum JourneyStage {
  /// Issued but not yet presented at a validator.
  notYetBoarded,

  /// Entry scanned. The passenger is on the vehicle right now.
  ///
  /// **This is not a problem state.** A ticket can legitimately stay here for
  /// the whole ride, and modelling it as anything alarming — a warning, a
  /// "partially used" badge — would tell a passenger mid-journey that
  /// something is wrong when nothing is.
  onboard,

  /// Both scans recorded. The ride is closed and the ticket is spent.
  alighted,
}

/// One recorded scan, as returned by the server.
///
/// `TicketValidation` is append-only on the backend, and this is the client
/// mirror of a row in it. Two of these per ticket is the normal, healthy case.
class TicketValidationRecord extends Equatable {
  const TicketValidationRecord({
    required this.kind,
    required this.scannedAt,
    this.tripId,
    this.deviceId,
  });

  final ValidationKind kind;
  final DateTime scannedAt;
  final String? tripId;

  /// Which physical device produced the scan. Present so a dispute can name the
  /// handheld rather than arguing about whose word to take.
  final String? deviceId;

  static TicketValidationRecord? fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? json['validationKind'] as String?;
    final scannedAt = json['scannedAt'] as String? ?? json['validatedAt'] as String?;
    if (kind == null || scannedAt == null) return null;

    final parsed = DateTime.tryParse(scannedAt);
    // An unparseable record is dropped rather than defaulted: inventing a
    // timestamp would put a passenger onboard at a time that never happened.
    if (parsed == null) return null;

    return TicketValidationRecord(
      kind: ValidationKind.fromWire(kind),
      scannedAt: parsed.toLocal(),
      tripId: json['tripId'] as String?,
      deviceId: json['deviceId'] as String?,
    );
  }

  @override
  List<Object?> get props => [kind, scannedAt, tripId, deviceId];
}

/// Works out the [JourneyStage] from the two recorded scans.
///
/// A pure function so the rule lives in exactly one place. The mistake it exists
/// to prevent: treating "entered but not exited" as a fault, when it is simply a
/// passenger in the middle of their journey.
JourneyStage resolveStage({
  TicketValidationRecord? entry,
  TicketValidationRecord? exit,
}) {
  if (exit != null) return JourneyStage.alighted;
  if (entry != null) return JourneyStage.onboard;
  return JourneyStage.notYetBoarded;
}

/// Whether a scan of [kind] is currently permitted.
///
/// The client-side mirror of the server rule, and it exists so the UI can
/// explain *why* a scan will be refused rather than letting the passenger
/// discover it at a gate. The server remains the authority — this is never
/// consulted in place of asking it.
bool canScan(
  ValidationKind kind, {
  TicketValidationRecord? entry,
  TicketValidationRecord? exit,
}) {
  final stage = resolveStage(entry: entry, exit: exit);
  return switch (kind) {
    // Entry is permitted exactly once. This is the single-use guarantee.
    ValidationKind.entry => stage == JourneyStage.notYetBoarded,
    // Exit is permitted only after an entry, and only once.
    ValidationKind.exit => stage == JourneyStage.onboard,
  };
}
/// The server's answer to a scan.
///
/// A sealed union rather than a flag, because the reasons a scan is refused are
/// not interchangeable to the person standing in front of the vehicle. "This
/// ticket has expired" and "this ticket has already been used" send a paying
/// passenger to completely different places — the queue, or the fare office.
sealed class ValidationOutcome extends Equatable {
  const ValidationOutcome();

  /// True when the scan was accepted and recorded.
  bool get isAccepted => this is EntryAccepted || this is ExitAccepted;

  /// True when the scan was refused. Every refusal carries a reason, because a
  /// bare "no" at a gate is how a fare dispute escalates.
  bool get isRefused => this is RefusedOutcome;

  @override
  List<Object?> get props => [];
}

/// Entry recorded. The passenger is on board.
class EntryAccepted extends ValidationOutcome {
  const EntryAccepted({required this.record});

  final TicketValidationRecord record;

  @override
  List<Object?> get props => [record];
}

/// Exit recorded. The ride is closed; the ticket is spent.
class ExitAccepted extends ValidationOutcome {
  const ExitAccepted({required this.record});

  final TicketValidationRecord record;

  @override
  List<Object?> get props => [record];
}

/// Base for every refusal.
///
/// Carries [kind] so a refusal is attributed to the scan that caused it: an exit
/// refused for a missing entry is a different event from an entry refused as a
/// duplicate, and they belong in different audit records.
sealed class RefusedOutcome extends ValidationOutcome {
  const RefusedOutcome({required this.kind, this.reason});

  final ValidationKind kind;
  final String? reason;

  @override
  List<Object?> get props => [kind, reason];
}

/// The credential is good but the ticket cannot be used right now.
class ValidationRefused extends RefusedOutcome {
  const ValidationRefused({required super.kind, super.reason});

  @override
  List<Object?> get props => [kind, reason];
}

/// **This ticket has already been scanned at this end of the journey.**
///
/// The single most important refusal to get right. Accepting a second ENTRY
/// would let one fare board an unbounded number of people, and it is the exact
/// hole that entry/exit pairing exists to close.
class AlreadyScannedAt extends RefusedOutcome {
  const AlreadyScannedAt({
    required super.kind,
    required this.firstScanAt,
    super.reason,
  });

  final DateTime firstScanAt;

  @override
  List<Object?> get props => [kind, firstScanAt, reason];
}

/// An EXIT was presented for a ticket with no recorded ENTRY.
///
/// Should not happen on a correctly ordered journey, so it is a replay, a scan
/// at the wrong end, or a forged pairing. Refused either way.
class ExitWithoutEntry extends RefusedOutcome {
  const ExitWithoutEntry({super.reason}) : super(kind: ValidationKind.exit);

  @override
  List<Object?> get props => [reason];
}

/// The credential did not verify.
class InvalidSignature extends RefusedOutcome {
  const InvalidSignature({super.reason}) : super(kind: ValidationKind.entry);

  @override
  List<Object?> get props => [reason];
}

/// The ticket is past its expiry.
///
/// [kind] is which end caught it, because expiry can be detected at entry or at
/// exit and the two appear in different audit records.
class TicketExpired extends RefusedOutcome {
  const TicketExpired({
    required this.expiresAt,
    super.kind = ValidationKind.entry,
    super.reason,
  });

  final DateTime expiresAt;

  @override
  List<Object?> get props => [expiresAt, kind, reason];
}

/// Parses the server's verdict.
///
/// Anything unrecognised becomes a plain [ValidationRefused] carrying whatever
/// detail came with it, rather than throwing. This is read while a passenger is
/// standing at a vehicle, and an exception here is a crash at the worst possible
/// moment. An unknown verdict must never be treated as ACCEPTED either — that
/// would let a malformed response through a gate.
ValidationOutcome validationOutcomeFromJson(Map<String, dynamic> json) {
  final verdict =
      (json['outcome'] as String? ?? json['status'] as String?)?.toUpperCase().trim();

  final kind = ValidationKind.fromWire(
    json['kind'] as String? ?? json['validationKind'] as String?,
  );

  final recordJson = json['validation'] as Map<String, dynamic>?;
  final record = recordJson == null
      ? null
      : TicketValidationRecord.fromJson(recordJson);

  return switch (verdict) {
    'ENTRY_ACCEPTED' || 'VALID_ENTRY' => EntryAccepted(
        record: record ??
            TicketValidationRecord(kind: kind, scannedAt: DateTime.now()),
      ),
    'EXIT_ACCEPTED' || 'VALID_EXIT' => ExitAccepted(
        record: record ??
            TicketValidationRecord(kind: kind, scannedAt: DateTime.now()),
      ),
    'ALREADY_USED' ||
    'ALREADY_SCANNED' ||
    'DUPLICATE' =>
      AlreadyScannedAt(
        kind: kind,
        firstScanAt: DateTime.tryParse(json['firstScanAt'] as String? ?? '')
                ?.toLocal() ??
            DateTime.now(),
      ),
    'EXIT_WITHOUT_ENTRY' => const ExitWithoutEntry(),
    'INVALID_SIGNATURE' => const InvalidSignature(),
    'EXPIRED' => TicketExpired(
        expiresAt:
            DateTime.tryParse(json['expiresAt'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
      ),
    _ => ValidationRefused(kind: kind, reason: json['reasonDetail'] as String?),
  };
}
