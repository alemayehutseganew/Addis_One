/**
 * Driver duties — assigned trips.
 *
 * A driver owns the run of a vehicle on a route: departing, arriving, completing
 * it. Those writes are the only place the operational timeline is observed rather
 * than inferred, so the delay and completion figures in the dashboard depend
 * entirely on this being honest.
 *
 * Trips are scoped to the driver's operator. A role grant alone is not scope: an
 * OPERATOR_ADMIN runs one network, and a driver from another network must not be
 * able to start their run.
 */

import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { TripStatus } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { operatorScope, StaffPrincipal } from '../auth/staff.guard';

/**
 * Permitted trip transitions.
 *
 * Stated here rather than spread across handlers so the rules read in one place.
 * The edges that matter: a trip cannot complete before it has departed, and
 * nothing resurrects a cancelled or completed run.
 */
const TRIP_TRANSITIONS: Record<TripStatus, readonly TripStatus[]> = {
  SCHEDULED: ['BOARDING', 'DELAYED', 'CANCELLED'],
  BOARDING: ['IN_PROGRESS', 'DELAYED', 'CANCELLED'],
  IN_PROGRESS: ['COMPLETED', 'DELAYED'],
  DELAYED: ['BOARDING', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'],
  COMPLETED: [],
  CANCELLED: [],
};

@Injectable()
export class MobilityService {
  private readonly log = new Logger(MobilityService.name);

  constructor(private readonly prisma: PrismaService) {}

  /**
   * The trips this staff member may work, for one day.
   *
   * The day window is UTC midnight on purpose: the parameter names a calendar
   * day, and letting the server's own timezone pick the boundary would make the
   * same query return different trips depending on where it runs.
   */
  async myTrips(staff: StaffPrincipal, date?: string) {
    const day = this.resolveDay(date);
    const scope = operatorScope(staff);

    const trips = await this.prisma.trip.findMany({
      where: {
        scheduledDeparture: { gte: day.start, lt: day.end },
        ...(scope ? { operatorId: scope } : {}),
      },
      orderBy: { scheduledDeparture: 'asc' },
      include: { route: true, vehicle: true },
    });

    return {
      date: day.label,
      trips: trips.map((t) => ({
        id: t.id,
        routeName: t.route.name,
        routeCode: t.route.code,
        direction: t.direction,
        vehiclePlate: t.vehicle.code,
        vehicleId: t.vehicleId,
        tripSequence: t.tripSequence,
        scheduledDeparture: t.scheduledDeparture,
        actualDeparture: t.actualDeparture,
        actualArrival: t.actualArrival,
        status: t.status,
        delaySeconds: t.delaySeconds,
        // Surfaced so a driver can see whether starting is even permitted,
        // rather than discovering it by being refused.
        availableTransitions: TRIP_TRANSITIONS[t.status as TripStatus] ?? [],
      })),
    };
  }

  /** Tickets issued against one trip — the conductor's manifest. */
  async manifest(staff: StaffPrincipal, tripId: string) {
    const trip = await this.loadScopedTrip(staff, tripId);

    const tickets = await this.prisma.ticket.findMany({
      where: { tripId: trip.id },
      orderBy: { issuedAt: 'desc' },
      include: { credential: true, user: { select: { displayName: true } } },
    });

    return {
      tripId: trip.id,
      status: trip.status,
      ticketCount: tickets.length,
      validatedCount: tickets.filter(
        (t) => t.status === 'VALIDATED' || t.status === 'COMPLETED',
      ).length,
      tickets: tickets.map((t) => ({
        reference: t.reference,
        status: t.status,
        mode: t.mode,
        passengerName: t.user.displayName,
        issuedAt: t.issuedAt,
        expiresAt: t.credential?.expiresAt ?? t.expiresAt,
      })),
    };
  }

  /** Departs a trip, stamping the real departure time. */
  async startTrip(staff: StaffPrincipal, tripId: string) {
    return this.transition(staff, tripId, ['BOARDING', 'IN_PROGRESS'], {
      status: TripStatus.IN_PROGRESS,
      actualDeparture: new Date(),
    });
  }

  /** Completes a trip, stamping arrival and the delay actually incurred. */
  async completeTrip(staff: StaffPrincipal, tripId: string) {
    const trip = await this.loadScopedTrip(staff, tripId);
    const now = new Date();

    // The permitted SOURCE state is IN_PROGRESS — a trip cannot be completed
    // before it has departed. This previously read ['COMPLETED'], which made
    // completion unreachable: the guard asked whether the trip was already
    // finished before letting it finish, so no trip could ever be completed.
    // Unit-testing the happy path would not have caught it, because only a real
    // trip in a real running state exercises it.
    const result = await this.transition(staff, tripId, [TripStatus.IN_PROGRESS], {
      status: TripStatus.COMPLETED,
      actualArrival: now,
      // Delay is measured against the schedule here rather than accepted from
      // the client, so the dashboard cannot be fed a flattering figure.
      delaySeconds: trip.scheduledArrival
        ? Math.max(0, Math.round((now.getTime() - trip.scheduledArrival.getTime()) / 1000))
        : null,
    });

    this.log.log(`Trip ${trip.id} completed`);
    return result;
  }

  /**
   * Applies a guarded status change.
   *
   * The permitted source states are listed by the caller rather than derived
   * from the transition map, because "depart" and "complete" are the only two
   * operations a driver performs here and the map alone would also let this
   * endpoint, say, reopen a cancelled trip.
   */
  private async transition(
    staff: StaffPrincipal,
    tripId: string,
    from: readonly TripStatus[],
    data: Record<string, unknown>,
  ) {
    const trip = await this.loadScopedTrip(staff, tripId);
    const current = trip.status as TripStatus;

    if (!from.includes(current)) {
      throw new BadRequestException(
        `Cannot perform this action on a trip that is ${current}.`,
      );
    }

    const updated = await this.prisma.trip.update({
      where: { id: trip.id },
      data,
      include: { route: true, vehicle: true },
    });

    return {
      id: updated.id,
      status: updated.status,
      routeName: updated.route.name,
      vehiclePlate: updated.vehicle.code,
      scheduledDeparture: updated.scheduledDeparture,
      actualDeparture: updated.actualDeparture,
      actualArrival: updated.actualArrival,
      delaySeconds: updated.delaySeconds,
    };
  }

  /**
   * Loads a trip the caller is entitled to act on.
   *
   * Both checks matter: the row must exist, and it must belong to the caller's
   * operator. A city-wide role skips the operator test because its grant *is* the
   * whole city, not because the check was forgotten.
   */
  private async loadScopedTrip(staff: StaffPrincipal, tripId: string) {
    const trip = await this.prisma.trip.findUnique({
      where: { id: tripId },
      include: { route: true, vehicle: true },
    });
    if (!trip) throw new NotFoundException('Trip not found');

    const scope = operatorScope(staff);
    if (scope !== null && trip.operatorId !== scope) {
      throw new ForbiddenException('Trip belongs to a different operator');
    }
    return trip;
  }

  private resolveDay(date?: string) {
    const label = date ?? new Date().toISOString().slice(0, 10);
    const parsed = new Date(`${label}T00:00:00.000Z`);
    if (Number.isNaN(parsed.getTime())) {
      throw new BadRequestException(`Invalid date: ${label}`);
    }
    return {
      label,
      start: parsed,
      end: new Date(parsed.getTime() + 24 * 60 * 60 * 1000),
    };
  }
}