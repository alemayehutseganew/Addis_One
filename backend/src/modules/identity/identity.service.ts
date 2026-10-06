/**
 * Staff shifts and device enrolment.
 *
 * A shift exists so that cash taken at a stop can be reconciled. Cash is the one
 * revenue stream that does not touch a payment provider, so nothing else in the
 * system records who physically held it. Without a shift a ticket officer's
 * takings are revenue with no audit trail and no way to detect a shortfall.
 *
 * The variance is always computed here from the payments actually recorded
 * against the shift. The client sends what is physically in the drawer; it never
 * sends what that should have been, because a client that could state the
 * expected figure could simply state one matching the cash it is holding.
 *
 * All money is in fils (integers), as everywhere else in the platform.
 */

import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { ShiftStatus } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';
import { operatorScope, StaffPrincipal } from '../auth/staff.guard';

export interface OpenShiftInput {
  staff: StaffPrincipal;
  vehicleId?: string | null;
  tripId?: string | null;
  openingCashFils: number;
}

@Injectable()
export class IdentityService {
  private readonly log = new Logger(IdentityService.name);

  constructor(private readonly prisma: PrismaService) {}

  // ── Shifts ────────────────────────────────────────────────────────────────

  /**
   * Opens a shift for the calling staff member.
   *
   * A staff member may hold only one open shift. Two open shifts would make
   * "the cash in this shift" ambiguous, which is the whole reason the record
   * exists — so the second attempt is refused rather than silently creating a
   * parallel ledger that reconciliation cannot resolve.
   */
  async openShift(input: OpenShiftInput) {
    const operatorId = this.requireOperator(input.staff);

    const existing = await this.prisma.shift.findFirst({
      where: { staffId: input.staff.id, status: ShiftStatus.OPEN },
    });
    if (existing) {
      throw new BadRequestException(
        `Staff member already has an open shift (${existing.reference}). ` +
          'Close it before opening another.',
      );
    }

    const shift = await this.prisma.shift.create({
      data: {
        reference:
          `SFT-${Date.now().toString(36).toUpperCase()}-` +
          randomUUID().slice(0, 6).toUpperCase(),
        staffId: input.staff.id,
        operatorId,
        vehicleId: input.vehicleId ?? null,
        tripId: input.tripId ?? null,
        openingCashFils: input.openingCashFils,
        // With no sales yet, expected equals what was placed in the drawer.
        expectedCashFils: input.openingCashFils,
        status: ShiftStatus.OPEN,
      },
    });

    this.log.log(`Shift ${shift.reference} opened by ${input.staff.id}`);
    return this.present(shift);
  }

  /** The calling staff member's current or most recent shift. */
  async myShift(staff: StaffPrincipal) {
    const shift = await this.prisma.shift.findFirst({
      where: { staffId: staff.id },
      orderBy: { openedAt: 'desc' },
      include: { vehicle: true, trip: true },
    });
    return shift ? this.present(shift) : null;
  }

  /**
   * Declares the cash physically held at close of a shift.
   *
   * The expected figure is recomputed here from the payments recorded against
   * this shift, so a stale figure cached on the handheld is irrelevant. The shift
   * moves to RECONCILING rather than straight to CLOSED on a variance: a
   * shortfall is a matter for a supervisor, and closing it silently would bury
   * exactly the case the record exists to catch.
   */
  async declareCash(staff: StaffPrincipal, shiftId: string, declaredCashFils: number) {
    const shift = await this.prisma.shift.findUnique({ where: { id: shiftId } });
    if (!shift) throw new NotFoundException('Shift not found');

    // Declaring only your own drawer is the rule. Even a city-wide supervisor
    // cannot file another officer's count, because the declaration is a
    // statement about what that person physically held.
    if (shift.staffId !== staff.id) {
      throw new ForbiddenException('Shift belongs to another staff member');
    }
    if (shift.status !== ShiftStatus.OPEN) {
      throw new BadRequestException(`Shift is ${shift.status}; nothing to declare`);
    }

    const sales = await this.prisma.payment.aggregate({
      where: { shiftId: shift.id, status: 'CONFIRMED' },
      _sum: { amountFils: true },
    });

    const taken = sales._sum.amountFils ?? 0;
    const expected = shift.openingCashFils + taken;

    const updated = await this.prisma.shift.update({
      where: { id: shift.id },
      data: {
        declaredCashFils,
        expectedCashFils: expected,
        varianceFils: declaredCashFils - expected,
        status:
          declaredCashFils === expected ? ShiftStatus.CLOSED : ShiftStatus.RECONCILING,
        closedAt: new Date(),
      },
    });

    this.log.log(
      `Shift ${shift.reference} declared ${declaredCashFils} against ` +
        `expected ${expected} (variance ${declaredCashFils - expected})`,
    );

    return {
      ...this.present(updated),
      cashTakenDuringShiftFils: taken,
      // Stated plainly so the officer sees the same arithmetic the server did.
      balanced: declaredCashFils === expected,
      nextStep:
        declaredCashFils === expected
          ? 'Shift closed and balanced.'
          : 'Variance recorded. A supervisor must review this shift.',
    };
  }

  /** Shifts awaiting a supervisor decision on their variance. */
  async variances(staff: StaffPrincipal) {
    const scope = operatorScope(staff);
    const rows = await this.prisma.shift.findMany({
      where: {
        status: ShiftStatus.RECONCILING,
        ...(scope ? { operatorId: scope } : {}),
      },
      orderBy: { openedAt: 'desc' },
      take: 100,
      include: { staff: { select: { user: { select: { displayName: true } } } } },
    });

    return rows.map((s) => ({
      ...this.present(s),
      staffDisplayName: s.staff.user.displayName,
    }));
  }

  // ── Devices ───────────────────────────────────────────────────────────────

  /**
   * Handshelds enrolled by this staff member.
   *
   * Enrolment is what binds a device's Ed25519 public key for offline
   * validation, so it is scoped to the caller rather than exposed network-wide.
   */
  async devices(staff: StaffPrincipal) {
    const rows = await this.prisma.staffDevice.findMany({
      where: { staffId: staff.id },
      include: { device: true },
    });

    return rows.map((r) => ({
      id: r.id,
      deviceId: r.deviceId,
      deviceCode: r.device.deviceCode,
      platform: r.device.platform,
      appVersion: r.device.appVersion,
      isEnrolled: r.isEnrolled,
      enrolledAt: r.enrolledAt,
      lastSyncAt: r.lastSyncAt,
      pendingCount: r.pendingCount,
      syncCursor: r.syncCursor,
      // A revoked device keeps its row so the revocation itself is auditable,
      // but can no longer validate offline.
      revoked: r.revokedAt !== null,
    }));
  }

  /**
   * Enrols an existing, registered device to this staff member.
   *
   * The Device row is not created here: a device announces itself when it is
   * installed, and enrolment is a separate, deliberate act that binds it to a
   * named officer. Letting this endpoint mint devices would make enrolment
   * meaningless as a control.
   */
  async enrollDevice(staff: StaffPrincipal, deviceId: string) {
    const device = await this.prisma.device.findUnique({ where: { id: deviceId } });
    if (!device) throw new NotFoundException('Device not found');
    if (!device.isActive) {
      throw new ForbiddenException('Device is disabled and cannot be enrolled');
    }

    const link = await this.prisma.staffDevice.upsert({
      where: { staffId_deviceId: { staffId: staff.id, deviceId } },
      create: {
        staffId: staff.id,
        deviceId,
        isEnrolled: true,
        enrolledAt: new Date(),
      },
      update: { isEnrolled: true, enrolledAt: new Date(), revokedAt: null },
    });

    this.log.log(`Device ${device.deviceCode} enrolled to ${staff.id}`);
    return {
      id: link.id,
      deviceId,
      deviceCode: device.deviceCode,
      isEnrolled: link.isEnrolled,
      enrolledAt: link.enrolledAt,
    };
  }

  /**
   * The caller's currently open shift, or a refusal.
   *
   * Required before any cash sale can be recorded. A ticket officer who has not
   * opened a drawer has nowhere to put the money, and letting a sale proceed
   * without a shift would produce exactly the untraceable revenue the shift
   * record exists to prevent.
   */
  async requireOpenShift(staff: StaffPrincipal) {
    const shift = await this.prisma.shift.findFirst({
      where: { staffId: staff.id, status: ShiftStatus.OPEN },
    });
    if (!shift) {
      throw new BadRequestException(
        'Open a shift before taking a sale. Cash takings must be attributable ' +
          'to a drawer that can be reconciled.',
      );
    }
    return shift;
  }

  /**
   * A field role must be attached to an operator.
   *
   * A city-wide role (bureau, finance) has no drawer to open, so opening a shift
   * under one is refused rather than written with a null operator — a shift whose
   * operator cannot be determined cannot be reconciled against anything.
   */
  private requireOperator(staff: StaffPrincipal): string {
    const scope = operatorScope(staff);
    if (!scope) {
      throw new ForbiddenException(
        'Only staff attached to an operator can open a shift. ' +
          'City-wide roles hold no cash.',
      );
    }
    return scope;
  }

  private present(shift: Record<string, unknown>) {
    return {
      id: shift.id,
      reference: shift.reference,
      status: shift.status,
      operatorId: shift.operatorId,
      vehicleId: shift.vehicleId ?? null,
      tripId: shift.tripId ?? null,
      openedAt: shift.openedAt,
      closedAt: shift.closedAt ?? null,
      openingCashFils: shift.openingCashFils,
      expectedCashFils: shift.expectedCashFils,
      declaredCashFils: shift.declaredCashFils ?? null,
      varianceFils: shift.varianceFils ?? null,
    };
  }
}