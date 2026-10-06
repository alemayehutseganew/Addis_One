/**
 * Complaints — the citizen-facing channel into the assurance function.
 *
 * Complaints are written by passengers and resolved by staff, so this module
 * holds the only endpoints legitimately reachable by a non-staff caller *and*
 * usable by staff. That is why it is not folded into /admin: the create route
 * needs JwtAuthGuard but must NOT carry StaffGuard, or no passenger could file
 * one.
 *
 * Resolution is append-only in spirit — a resolved complaint keeps its text and
 * gains a resolution rather than being edited into agreement.
 */

import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { ComplaintCategory, ComplaintStatus } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';
import { operatorScope, StaffPrincipal } from '../auth/staff.guard';

/** Terminal states: no further transition is permitted. */
const TERMINAL: readonly ComplaintStatus[] = [
  ComplaintStatus.RESOLVED,
  ComplaintStatus.CLOSED,
  ComplaintStatus.REJECTED,
];

/**
 * Permitted complaint transitions.
 *
 * A complaint cannot go back to OPEN once resolved. Reopening is a new
 * complaint — which is the difference between "we got this wrong" and "this never
 * happened".
 */
const TRANSITIONS: Record<ComplaintStatus, readonly ComplaintStatus[]> = {
  OPEN: [ComplaintStatus.ASSIGNED, ComplaintStatus.INVESTIGATING, ComplaintStatus.REJECTED],
  ASSIGNED: [
    ComplaintStatus.INVESTIGATING,
    ComplaintStatus.WAITING_ON_CUSTOMER,
    ComplaintStatus.REJECTED,
  ],
  INVESTIGATING: [
    ComplaintStatus.WAITING_ON_CUSTOMER,
    ComplaintStatus.RESOLVED,
    ComplaintStatus.REJECTED,
  ],
  WAITING_ON_CUSTOMER: [ComplaintStatus.INVESTIGATING, ComplaintStatus.RESOLVED],
  RESOLVED: [ComplaintStatus.CLOSED],
  CLOSED: [],
  REJECTED: [],
};

export interface FileComplaintInput {
  userId: string | null;
  category: ComplaintCategory;
  description: string;
  ticketId?: string | null;
  paymentId?: string | null;
  routeId?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  channel?: string;
}

@Injectable()
export class AssuranceService {
  private readonly log = new Logger(AssuranceService.name);

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Files a complaint.
   *
   * The operator is derived from the referenced ticket rather than taken from the
   * client, so a complaint cannot be aimed at a rival operator by pointing it at
   * an unrelated ticket.
   */
  async file(input: FileComplaintInput) {
    let operatorId: string | null = null;
    if (input.ticketId) {
      const ticket = await this.prisma.ticket.findUnique({
        where: { id: input.ticketId },
        select: { journeyId: true },
      });
      if (ticket?.journeyId) {
        // JourneyLeg carries routeId but no `route` relation is selected on it,
        // so the operator is resolved through the Route itself rather than by
        // reaching through a relation that is not there.
        const leg = await this.prisma.journeyLeg.findFirst({
          where: { journeyId: ticket.journeyId },
          select: { routeId: true },
        });
        if (leg?.routeId) {
          const route = await this.prisma.route.findUnique({
            where: { id: leg.routeId },
            select: { operatorId: true },
          });
          operatorId = route?.operatorId ?? null;
        }
      }
    }

    const complaint = await this.prisma.complaint.create({
      data: {
        reference:
          `CMP-${Date.now().toString(36).toUpperCase()}-` +
          randomUUID().slice(0, 6).toUpperCase(),
        userId: input.userId,
        category: input.category,
        // SAFETY is escalated by default. A safety complaint sitting at the bottom
        // of a queue behind a lost umbrella is a failure of triage, not priority.
        priority: input.category === ComplaintCategory.SAFETY ? 1 : 3,
        description: input.description,
        ticketId: input.ticketId ?? null,
        paymentId: input.paymentId ?? null,
        routeId: input.routeId ?? null,
        operatorId,
        geoLatitude: input.latitude ?? null,
        geoLongitude: input.longitude ?? null,
        channel: input.channel ?? 'APP',
        status: ComplaintStatus.OPEN,
      },
    });

    this.log.log(`Complaint ${complaint.reference} filed (${input.category})`);
    return {
      reference: complaint.reference,
      status: complaint.status,
      category: complaint.category,
      priority: complaint.priority,
      createdAt: complaint.createdAt,
    };
  }

  /**
   * Complaints in the caller's scope.
   *
   * A field role sees only its own operator's complaints; a city-wide role sees
   * everything. Sorted by priority then age, because the point of the queue is
   * deciding what to work on next.
   */
  async list(staff: StaffPrincipal, status?: string) {
    const scope = operatorScope(staff);
    const rows = await this.prisma.complaint.findMany({
      where: {
        ...(scope ? { operatorId: scope } : {}),
        ...(status ? { status: status as ComplaintStatus } : {}),
      },
      orderBy: [{ priority: 'asc' }, { createdAt: 'asc' }],
      take: 100,
    });

    return rows.map((c) => ({
      reference: c.reference,
      category: c.category,
      status: c.status,
      priority: c.priority,
      description: c.description,
      resolution: c.resolution,
      channel: c.channel,
      operatorId: c.operatorId,
      createdAt: c.createdAt,
      resolvedAt: c.resolvedAt,
    }));
  }

  /** The signed-in passenger's own complaints. */
  async mine(userId: string) {
    const rows = await this.prisma.complaint.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: 50,
    });
    return rows.map((c) => ({
      reference: c.reference,
      category: c.category,
      status: c.status,
      description: c.description,
      resolution: c.resolution,
      createdAt: c.createdAt,
      resolvedAt: c.resolvedAt,
    }));
  }

  /**
   * Advances a complaint.
   *
   * Resolving requires a written resolution. A status flip with no explanation
   * produces a queue that is closed but not answered, which from the passenger's
   * side is indistinguishable from being ignored.
   */
  async advance(
    staff: StaffPrincipal,
    reference: string,
    next: ComplaintStatus,
    resolution?: string,
  ) {
    const complaint = await this.prisma.complaint.findUnique({ where: { reference } });
    if (!complaint) throw new NotFoundException('Complaint not found');

    const scope = operatorScope(staff);
    if (scope !== null && complaint.operatorId !== scope) {
      throw new ForbiddenException('Complaint belongs to a different operator');
    }

    const current = complaint.status as ComplaintStatus;
    if (TERMINAL.includes(current)) {
      throw new BadRequestException(`Complaint is already ${current}`);
    }
    if (!TRANSITIONS[current].includes(next)) {
      throw new BadRequestException(
        `Cannot move a complaint from ${current} to ${next}`,
      );
    }

    const resolving =
      next === ComplaintStatus.RESOLVED ||
      next === ComplaintStatus.REJECTED ||
      next === ComplaintStatus.CLOSED;
    if (resolving && !resolution?.trim()) {
      throw new BadRequestException(
        'A written resolution is required to close or reject a complaint',
      );
    }

    const updated = await this.prisma.complaint.update({
      where: { id: complaint.id },
      data: {
        status: next,
        resolution: resolution ?? complaint.resolution,
        resolvedAt: resolving ? new Date() : complaint.resolvedAt,
        assignedToStaffId: staff.id,
      },
    });

    this.log.log(`Complaint ${reference} -> ${next}`);
    return {
      reference: updated.reference,
      status: updated.status,
      resolution: updated.resolution,
      resolvedAt: updated.resolvedAt,
    };
  }
}