/**
 * Ticket validation — the inspector's scanner. Implements architecture.md I5.
 *
 * The decision is made here, on the server, from the signed credential and the
 * stored ticket. The handheld renders the outcome; it never decides validity
 * itself. That is the same rule the passenger app obeys in the other direction:
 * a ticket is not valid because a phone said so.
 *
 * Every scan is written to `TicketValidation`, including the rejections. A fraud
 * pattern is only visible if refusals are recorded with the same fidelity as the
 * acceptances, so a failed scan is not an error path that quietly returns 4xx
 * and leaves no trace — it is a row with outcome INVALID_SIGNATURE and the
 * reason recorded.
 */

import { Injectable, Logger } from '@nestjs/common';
import { ValidationOutcome } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';
import {
  CredentialSigner,
  VerifyFailureReason,
} from '../ticketing/credential-signer';
import { checkTransition, TicketStatus } from '../ticketing/ticket-state-machine';
import { operatorScope, StaffPrincipal } from '../auth/staff.guard';

export interface ScanInput {
  qrString: string;
  staff: StaffPrincipal;
  /** The trip the inspector is working. Optional, but scopes the record. */
  tripId?: string | null;
  deviceId?: string | null;
  latitude?: number | null;
  longitude?: number | null;
}

export interface ScanResult {
  /** True only when the passenger may board on this evidence. */
  accepted: boolean;
  outcome: ValidationOutcome;
  /** Human-readable explanation for the officer on the spot. */
  reason: string;
  ticketReference: string | null;
  validatedAt: string;
  validationReference: string;
}

/**
 * Maps a cryptographic failure onto the outcome vocabulary the schema defines.
 *
 * Kept as a table rather than nested conditionals because this is the one place
 * where a confusing code does real damage: an officer told NOT_ISSUED when the
 * truth is EXPIRED sends a paying passenger away from a vehicle they were
 * entitled to board.
 */
const SIGNATURE_OUTCOMES: Record<VerifyFailureReason, ValidationOutcome> = {
  MALFORMED: ValidationOutcome.INVALID,
  UNSUPPORTED_VERSION: ValidationOutcome.INVALID,
  BAD_SIGNATURE: ValidationOutcome.INVALID_SIGNATURE,
  EXPIRED: ValidationOutcome.EXPIRED,
  NOT_YET_VALID: ValidationOutcome.INVALID,
  UNKNOWN_KEY: ValidationOutcome.UNKNOWN_CREDENTIAL,
};

const OUTCOME_REASONS: Partial<Record<ValidationOutcome, string>> = {
  [ValidationOutcome.INVALID]: 'The scanned code is not a readable ticket credential.',
  [ValidationOutcome.INVALID_SIGNATURE]:
    'The credential signature does not match. Treat as a forged or altered ticket.',
  [ValidationOutcome.EXPIRED]: 'The ticket expired. It is only valid for its stated window.',
  [ValidationOutcome.UNKNOWN_CREDENTIAL]:
    'This credential does not correspond to any ticket issued by this system.',
  [ValidationOutcome.NOT_ISSUED]:
    'This ticket has not been issued yet. A payment callback alone does not issue a ticket.',
  [ValidationOutcome.ALREADY_USED]: 'This ticket has already been used for boarding.',
  [ValidationOutcome.REVOKED]: 'This ticket has been cancelled or refunded.',
  [ValidationOutcome.WRONG_TRIP]:
    'This ticket is not valid for the trip being boarded.',
  [ValidationOutcome.WRONG_MODE]: 'This ticket is for a different mode of transport.',
};

@Injectable()
export class ValidationService {
  private readonly log = new Logger(ValidationService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly signer: CredentialSigner,
  ) {}

  async scan(input: ScanInput): Promise<ScanResult> {
    // ── 1. Is this a credential we issued, and is it intact? ────────────────
    const verified = CredentialSigner.verify(input.qrString, this.signer.publicKeys());

    if (!verified.valid) {
      return this.reject(
        input,
        SIGNATURE_OUTCOMES[verified.reason as VerifyFailureReason],
        verified.reason,
      );
    }

    // ── 2. The signature is ours. Now check the ticket behind it. ───────────
    const ticket = await this.prisma.ticket.findUnique({
      where: { id: verified.payload!.ticketId },
      include: { credential: true },
    });
    if (!ticket) return this.reject(input, ValidationOutcome.UNKNOWN_CREDENTIAL);

    const outcome = this.evaluate(
      ticket.status as TicketStatus,
      ticket.credential?.expiresAt ?? ticket.expiresAt,
    );
    if (outcome) return this.reject(input, outcome, null, ticket.reference);

    // ── 3. Operator boundary, enforced here rather than by role alone. ───────
    // An INSPECTOR role is not automatically entitled to every operator's
    // network. operatorScope returns null for city-wide roles; a field role is
    // pinned to one operator, so this denies a cross-operator inspection even
    // after the role check has already passed.
    const trip = await this.loadTrip(input.tripId);
    if (trip) {
      const scope = operatorScope(input.staff);
      if (scope !== null && trip.vehicle?.operatorId !== scope) {
        return this.reject(
          input,
          ValidationOutcome.WRONG_TRIP,
          'Trip belongs to a different operator',
          ticket.reference,
        );
      }
    }

    return this.accept(input, ticket);
  }

  /**
   * Advances the ticket to VALIDATED and records the acceptance atomically.
   *
   * The update is conditional on the ticket still being VALID. Two officers
   * scanning the same screenshot at the same instant both read VALID, so an
   * unconditional update would let both write and the second passenger would
   * board on one ticket. `updateMany` with a status predicate makes the database
   * arbitrate: exactly one call changes a row, and the loser is told the ticket
   * was already used rather than being handed a success.
   */
  private async accept(
    input: ScanInput,
    ticket: {
      id: string;
      reference: string;
      credential: { id: string } | null;
    },
  ): Promise<ScanResult> {
    const record = await this.prisma.$transaction(async (tx) => {
      const changed = await tx.ticket.updateMany({
        where: { id: ticket.id, status: 'VALID' },
        data: { status: 'VALIDATED', validatedAt: new Date() },
      });
      if (changed.count === 0) return null;

      return tx.ticketValidation.create({
        data: {
          reference: this.newReference(),
          ticketId: ticket.id,
          credentialId: ticket.credential?.id ?? null,
          outcome: ValidationOutcome.VALID,
          validatedByStaffId: input.staff.id,
          deviceId: input.deviceId ?? null,
          tripId: input.tripId ?? null,
          isOffline: false,
          syncState: 'SYNCED',
          geoLatitude: input.latitude ?? null,
          geoLongitude: input.longitude ?? null,
        },
      });
    });

    if (!record) {
      return this.reject(input, ValidationOutcome.ALREADY_USED, null, ticket.reference);
    }

    this.log.log(
      `Validated ${ticket.reference} by ${input.staff.employeeCode ?? input.staff.phone}`,
    );

    return {
      accepted: true,
      outcome: ValidationOutcome.VALID,
      reason: 'Ticket is valid for boarding.',
      ticketReference: ticket.reference,
      validatedAt: record.validatedAt.toISOString(),
      validationReference: record.reference,
    };
  }

  /**
   * The state check, expressed through the single source of truth.
   *
   * `checkTransition` is asked whether VALID -> VALIDATED is permitted rather
   * than re-implementing the rule here, so a change to the state machine cannot
   * leave the scanner enforcing a stale copy of it.
   */
  private evaluate(status: TicketStatus, expiresAt: Date): ValidationOutcome | null {
    if (expiresAt.getTime() <= Date.now()) return ValidationOutcome.EXPIRED;
    if (checkTransition(status, 'VALIDATED').allowed) return null;

    // Terminal and consumed states are distinguished so the officer gets the
    // actual reason rather than a generic refusal.
    if (status === 'VALIDATED' || status === 'COMPLETED') {
      return ValidationOutcome.ALREADY_USED;
    }
    if (status === 'TICKET_ISSUED') {
      // Issued but never activated. Issuing is not the same as being valid.
      return ValidationOutcome.NOT_ISSUED;
    }
    if (status === 'CANCELLED' || status === 'VOIDED' || status === 'REFUNDED') {
      return ValidationOutcome.REVOKED;
    }
    return ValidationOutcome.INVALID;
  }

  private async loadTrip(tripId: string | null | undefined) {
    if (!tripId) return null;
    return this.prisma.trip.findUnique({
      where: { id: tripId },
      include: { vehicle: true },
    });
  }

  /**
   * Records a refusal and returns it.
   *
   * The write happens even for a signature failure, because a forged credential
   * is precisely the thing worth keeping evidence of. It carries no ticket id,
   * which is why `ticketId` is nullable on the model.
   *
   * A failure to record must not fail the scan: the officer standing at the door
   * needs an answer more than the system needs an audit row, so a broken write
   * is logged loudly and the refusal is still returned.
   */
  private async reject(
    input: ScanInput,
    outcome: ValidationOutcome,
    detail?: string | null,
    ticketReference?: string | null,
  ): Promise<ScanResult> {
    let validationReference: string;
    try {
      const record = await this.prisma.ticketValidation.create({
        data: {
          reference: this.newReference(),
          outcome,
          reasonDetail: detail ?? null,
          validatedByStaffId: input.staff.id,
          deviceId: input.deviceId ?? null,
          tripId: input.tripId ?? null,
          isOffline: false,
          syncState: 'SYNCED',
          geoLatitude: input.latitude ?? null,
          geoLongitude: input.longitude ?? null,
        },
      });
      validationReference = record.reference;
    } catch (err) {
      this.log.error(
        `Could not record ${outcome} validation for ` +
          `${input.staff.employeeCode ?? input.staff.phone}: ${(err as Error).message}`,
      );
      validationReference = 'UNRECORDED';
    }

    this.log.warn(
      `Rejected scan by ${input.staff.employeeCode ?? input.staff.phone}: ${outcome}`,
    );

    return {
      accepted: false,
      outcome,
      reason: OUTCOME_REASONS[outcome] ?? 'This ticket cannot be accepted.',
      ticketReference: ticketReference ?? null,
      validatedAt: new Date().toISOString(),
      validationReference,
    };
  }

  /**
   * A single officer's recent scans, newest first.
   *
   * Deliberately limited to one officer. A network-wide validation feed records
   * who inspected whom, where and when, which is surveillance data with no
   * operational use on a handheld — and the sort of record that should be hard
   * to casually assemble. Oversight queries belong to the audit surface.
   */
  async recentForStaff(staffId: string, limit: number) {
    const rows = await this.prisma.ticketValidation.findMany({
      where: { validatedByStaffId: staffId },
      orderBy: { validatedAt: 'desc' },
      take: limit,
      include: { ticket: { select: { reference: true, mode: true } } },
    });

    return rows.map((r) => ({
      reference: r.reference,
      outcome: r.outcome,
      reasonDetail: r.reasonDetail,
      ticketReference: r.ticket?.reference ?? null,
      mode: r.ticket?.mode ?? null,
      validatedAt: r.validatedAt.toISOString(),
      isOffline: r.isOffline,
      syncState: r.syncState,
    }));
  }

  /**
   * Sortable, non-enumerable identifier in the style used across the platform
   * (TKT-, PAY-, CRD-). The timestamp prefix means rows are ordered by creation
   * when read as text, without needing the timestamp column.
   */
  private newReference(): string {
    return (
      `VAL-${Date.now().toString(36).toUpperCase()}-` +
      randomUUID().slice(0, 6).toUpperCase()
    );
  }
}