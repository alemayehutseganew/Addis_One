// Entry/exit validation — the Chennai-style half of the ticket lifecycle.
//
// A ticket is scanned TWICE: once to board, once to alight. These tests pin the
// two properties that make that worth doing over a flat "mark as used" flag:
//
//  1. The middle state exists and is treated as NORMAL. A passenger between
//     entry and exit is exactly where they should be. A single boolean has
//     nowhere to put them, which is why flat designs show them as either
//     unused or spent — both wrong.
//  2. Pairing enforces single use. A second ENTRY is refused, so one fare
//     cannot board two people. That control does not exist in a one-flag design.
import 'package:addis_one/core/models/ticket.dart';
import 'package:addis_one/core/models/ticket_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime(2026, 10, 1, 12);

  TicketValidationRecord scan(ValidationKind kind) =>
      TicketValidationRecord(kind: kind, scannedAt: at);

  IssuedTicket ticketWith({
    TicketValidationRecord? entry,
    TicketValidationRecord? exit,
  }) {
    return IssuedTicket(
      id: 'tkt-1',
      reference: 'TKT-1',
      status: TicketStatus.valid,
      issuedAt: at,
      expiresAt: at.add(const Duration(hours: 2)),
      entryValidation: entry,
      exitValidation: exit,
    );
  }

  group('Stage resolution', () {
    test('a fresh ticket has neither scan recorded', () {
      expect(resolveStage(), JourneyStage.notYetBoarded);
    });

    test('an entry scan alone means the passenger is onboard', () {
      expect(
        resolveStage(entry: scan(ValidationKind.entry)),
        JourneyStage.onboard,
      );
    });

    test('entry then exit closes the ride', () {
      expect(
        resolveStage(
          entry: scan(ValidationKind.entry),
          exit: scan(ValidationKind.exit),
        ),
        JourneyStage.alighted,
      );
    });

    test('an exit without an entry resolves to alighted, not onboard', () {
      // The server refuses this pairing; the client must not crash on it.
      expect(
        resolveStage(exit: scan(ValidationKind.exit)),
        JourneyStage.alighted,
      );
    });
  });

  group('Single use is enforced by pairing', () {
    test('ENTRY is permitted exactly once', () {
      // The control that stops one fare boarding two people.
      expect(canScan(ValidationKind.entry), isTrue);
      expect(
        canScan(ValidationKind.entry, entry: scan(ValidationKind.entry)),
        isFalse,
      );
    });

    test('a second entry is refused even after an exit', () {
      expect(
        canScan(ValidationKind.entry, exit: scan(ValidationKind.exit)),
        isFalse,
      );
    });

    test('EXIT is refused before an entry', () {
      // Cannot alight from a journey never joined.
      expect(canScan(ValidationKind.exit), isFalse);
    });

    test('EXIT is permitted only between entry and exit', () {
      final entry = scan(ValidationKind.entry);
      expect(canScan(ValidationKind.exit, entry: entry), isTrue);
      expect(
        canScan(
          ValidationKind.exit,
          entry: entry,
          exit: scan(ValidationKind.exit),
        ),
        isFalse,
      );
    });

    test('a ticket mirrors the rule through permits()', () {
      expect(ticketWith().permits(ValidationKind.entry), isTrue);
      expect(ticketWith().permits(ValidationKind.exit), isFalse);

      final boarded = ticketWith(entry: scan(ValidationKind.entry));
      expect(boarded.permits(ValidationKind.entry), isFalse);
      expect(boarded.permits(ValidationKind.exit), isTrue);
    });
  });

  group('Onboard is not a failure', () {
    test('a boarded ticket is neither spent nor in trouble', () {
      final boarded = ticketWith(entry: scan(ValidationKind.entry));

      expect(boarded.journeyStage, JourneyStage.onboard);
      expect(boarded.isFullyUsed, isFalse);
      // The regression this guards: rendering the middle state as a warning
      // tells a passenger mid-ride that something is wrong when nothing is.
      expect(boarded.status.isFailure, isFalse);
      expect(boarded.status.isUsable, isTrue);
    });

    test('only a completed ride is fully used', () {
      final done = ticketWith(
        entry: scan(ValidationKind.entry),
        exit: scan(ValidationKind.exit),
      );
      expect(done.journeyStage, JourneyStage.alighted);
      expect(done.isFullyUsed, isTrue);
    });
  });
group('Outcomes are distinguishable', () {
    test('accepted outcomes are not refusals', () {
      final accepted = EntryAccepted(
        record: TicketValidationRecord(
          kind: ValidationKind.entry,
          scannedAt: at,
        ),
      );
      expect(accepted.isAccepted, isTrue);
      expect(accepted.isRefused, isFalse);
    });

    test('every refusal is refused', () {
      expect(const ExitWithoutEntry().isRefused, isTrue);
      expect(const InvalidSignature().isRefused, isTrue);
      expect(
        AlreadyScannedAt(kind: ValidationKind.entry, firstScanAt: at).isRefused,
        isTrue,
      );
      expect(TicketExpired(expiresAt: at).isRefused, isTrue);
    });

    test('a duplicate carries the scan it duplicates', () {
      // Needed for the audit trail, and for telling a passenger WHEN the fare
      // was already used — "used at 12:10" is answerable, "already used" is not.
      final duplicate = AlreadyScannedAt(
        kind: ValidationKind.entry,
        firstScanAt: at,
      );
      expect(duplicate.kind, ValidationKind.entry);
      expect(duplicate.firstScanAt, at);
    });

    test('an exit-without-entry is attributed to the exit', () {
      expect(const ExitWithoutEntry().kind, ValidationKind.exit);
    });

    test('an unknown verdict is refused, never accepted', () {
      // A malformed or unexpected response must not open a gate.
      final outcome = validationOutcomeFromJson({'outcome': 'SOMETHING_NEW'});
      expect(outcome.isAccepted, isFalse);
      expect(outcome.isRefused, isTrue);
    });

    test('verdicts map to the right kind of acceptance', () {
      expect(
        validationOutcomeFromJson({
          'outcome': 'ENTRY_ACCEPTED',
          'validation': {
            'kind': 'ENTRY',
            'scannedAt': '2026-10-01T12:00:00Z',
          },
        }),
        isA<EntryAccepted>(),
      );
      expect(
        validationOutcomeFromJson({'outcome': 'EXIT_ACCEPTED'}),
        isA<ExitAccepted>(),
      );
    });

    test('a duplicate verdict becomes AlreadyScannedAt', () {
      expect(
        validationOutcomeFromJson({'outcome': 'ALREADY_USED'}),
        isA<AlreadyScannedAt>(),
      );
    });
  });

  group('Ledger parsing', () {
    test('a malformed scan record is dropped, not defaulted to "now"', () {
      // Inventing a timestamp would show a passenger as onboard at a moment
      // that never happened.
      expect(TicketValidationRecord.fromJson({'kind': 'ENTRY'}), isNull);
      expect(
        TicketValidationRecord.fromJson({
          'scannedAt': '2026-10-01T12:00:00Z',
        }),
        isNull,
      );
    });

    test('a valid scan record parses from the ledger shape', () {
      final record = TicketValidationRecord.fromJson({
        'kind': 'EXIT',
        'scannedAt': '2026-10-01T12:00:00Z',
        'deviceId': 'dev-1',
      });

      expect(record, isNotNull);
      expect(record!.kind, ValidationKind.exit);
      expect(record.deviceId, 'dev-1');
    });

    test('a ticket reads both scans out of the append-only ledger', () {
      final ticket = IssuedTicket.fromJson({
        'id': 'tkt-1',
        'status': 'VALID',
        'issuedAt': '2026-10-01T12:00:00Z',
        'expiresAt': '2026-10-01T14:00:00Z',
        'validations': [
          {'kind': 'ENTRY', 'scannedAt': '2026-10-01T12:10:00Z'},
          {'kind': 'EXIT', 'scannedAt': '2026-10-01T12:40:00Z'},
        ],
      });

      expect(ticket.entryValidation, isNotNull);
      expect(ticket.exitValidation, isNotNull);
      expect(ticket.isFullyUsed, isTrue);
    });

    test('an entry-only ledger leaves the ride open', () {
      final ticket = IssuedTicket.fromJson({
        'id': 'tkt-1',
        'status': 'VALID',
        'issuedAt': '2026-10-01T12:00:00Z',
        'expiresAt': '2026-10-01T14:00:00Z',
        'validations': [
          {'kind': 'ENTRY', 'scannedAt': '2026-10-01T12:10:00Z'},
        ],
      });

      expect(ticket.journeyStage, JourneyStage.onboard);
      expect(ticket.exitValidation, isNull);
    });

    test('a ticket with no ledger parses as not yet boarded', () {
      final ticket = IssuedTicket.fromJson({
        'id': 'tkt-1',
        'status': 'VALID',
        'issuedAt': '2026-10-01T12:00:00Z',
        'expiresAt': '2026-10-01T14:00:00Z',
      });

      expect(ticket.journeyStage, JourneyStage.notYetBoarded);
      expect(ticket.entryValidation, isNull);
      expect(ticket.exitValidation, isNull);
    });

    test('a malformed ledger row does not lose the valid ones', () {
      final ticket = IssuedTicket.fromJson({
        'id': 'tkt-1',
        'status': 'VALID',
        'issuedAt': '2026-10-01T12:00:00Z',
        'expiresAt': '2026-10-01T14:00:00Z',
        'validations': [
          {'kind': 'ENTRY'},
          {'kind': 'ENTRY', 'scannedAt': '2026-10-01T12:10:00Z'},
        ],
      });

      expect(ticket.entryValidation, isNotNull);
      expect(ticket.journeyStage, JourneyStage.onboard);
    });
  });
}