import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { PaymentStatus, Prisma, TicketStatus } from '@prisma/client';
import { StaffPrincipal, operatorScope } from '../auth/staff.guard';
import { PrismaService } from '../../prisma/prisma.service';
import { DateRange } from './dashboard-query';

/**
 * Read-only aggregates for the government and operator office dashboard.
 *
 * Every figure is computed in SQL rather than assembled from public endpoints.
 * Two reasons, and the second is the one that matters:
 *
 *  1. Correctness. "Revenue this month" summed in JavaScript from a page of rows
 *     is a number nobody checked, and it disagrees with the ledger in ways that
 *     surface months later during reconciliation.
 *  2. Exposure. A dashboard showing revenue, payment status and ridership must
 *     not be reachable by chaining public endpoints together. Aggregate-only,
 *     behind a staff guard, with no citizen-level rows, is a materially smaller
 *     thing to hand to a bureau than a table of transactions.
 *
 * Money is integer fils end to end. Nothing here divides by 100 or multiplies
 * by a rate, so no float can enter a reported total — see `common/money.ts` for
 * why that is treated as a correctness rule rather than a style preference.
 */
@Injectable()
export class DashboardService {
  private readonly logger = new Logger(DashboardService.name);

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Payment position, with the recent rows behind it.
   *
   * Grouped by status and method in SQL: an officer asking "how much money is
   * stuck" needs that answer without downloading every transaction to count
   * them, and the aggregate is less likely to be misread than a hand sum.
   */
  async revenue(
    staff: StaffPrincipal,
    range: DateRange,
    page: number,
    pageSize: number,
    status?: string,
  ) {
    const scope = operatorScope(staff);
    const statusFilter = status ? this.paymentStatus(status) : undefined;
    const filtered = this.paymentWhere(range, scope, statusFilter);

    const [totals, byStatus, byMethod, payments, total] = await Promise.all([
      this.paymentTotals(range, scope),
      this.prisma.payment.groupBy({
        by: ['status'],
        where: this.paymentWhere(range, scope),
        _count: { _all: true },
        _sum: { amountFils: true },
      }),
      this.prisma.payment.groupBy({
        by: ['method'],
        where: filtered,
        _count: { _all: true },
        _sum: { amountFils: true },
      }),
      this.prisma.payment.findMany({
        where: filtered,
        orderBy: { createdAt: 'desc' },
        skip: (page - 1) * pageSize,
        take: pageSize,
        // Deliberately narrow. No userId, no phone, no provider payload: the
        // payments table is the densest concentration of citizen identifiers in
        // the system, and none of it is needed to reconcile a day's takings.
        select: {
          reference: true,
          amountFils: true,
          currency: true,
          method: true,
          status: true,
          createdAt: true,
          confirmedAt: true,
        },
      }),
      this.prisma.payment.count({ where: filtered }),
    ]);

    return {
      range,
      totals,
      byStatus: byStatus.map((r) => ({
        status: r.status,
        count: r._count._all,
        amountFils: r._sum.amountFils ?? 0,
      })),
      byMethod: byMethod.map((r) => ({
        method: r.method,
        count: r._count._all,
        amountFils: r._sum.amountFils ?? 0,
      })),
      page,
      pageSize,
      total,
      pageCount: Math.max(1, Math.ceil(total / pageSize)),
      payments,
    };
  }

  /**
   * Headline figures plus the daily series behind them.
   *
   * `periodOverPeriod` compares against the immediately preceding window of the
   * same length rather than "last month", so a 7-day view is compared with the
   * 7 days before it. Comparing every window to a calendar month would make a
   * short view look flat and invite the reader to draw a conclusion from a
   * difference that is really just a change in window length.
   */
  async overview(staff: StaffPrincipal, range: DateRange) {
    const scope = operatorScope(staff);
    const previous: DateRange = {
      from: new Date(range.from.getTime() - range.days * 86_400_000),
      to: range.from,
      days: range.days,
    };

    const [
      payments,
      priorPayments,
      tickets,
      priorTickets,
      journeys,
      priorJourneys,
      revenue,
      journeySeries,
      network,
      passengers,
    ] = await Promise.all([
      this.paymentTotals(range, scope),
      this.paymentTotals(previous, scope),
      this.ticketTotals(range, scope),
      this.ticketTotals(previous, scope),
      this.journeyCount(range, scope),
      this.journeyCount(previous, scope),
      this.dailyRevenue(range, scope),
      this.dailyJourneys(range, scope),
      this.networkSnapshot(scope),
      this.passengerSnapshot(range),
    ]);

    return {
      generatedAt: new Date().toISOString(),
      range,
      scope: scope
        ? { operatorId: scope, cityWide: false }
        : { operatorId: null, cityWide: true },
      kpis: {
        // Gross is every attempted charge; settled is money actually received.
        // Publishing only one makes the other look like an error.
        grossCollectedFils: payments.grossFils,
        settledRevenueFils: payments.confirmedFils,
        settledPaymentCount: payments.confirmedCount,
        unsettledPaymentCount: payments.pendingCount,
        refundFils: payments.refundedFils,
        // Integer division with rounding, in fils. A float average would put a
        // fractional fils into a money field, which `money()` rightly rejects.
        averageTicketFils:
          payments.confirmedCount > 0
            ? Math.round(payments.confirmedFils / payments.confirmedCount)
            : 0,
        ticketCount: tickets.total,
        ticketsIssued: tickets.issued,
        journeyCount: journeys.total,
      },
      periodOverPeriod: {
        days: range.days,
        settledRevenueFils: payments.confirmedFils - priorPayments.confirmedFils,
        ticketCount: tickets.total - priorTickets.total,
        journeyCount: journeys.total - priorJourneys.total,
      },
      network,
      passengers,
      series: { revenue, journeys: journeySeries },
    };
  }

  /**
   * Fare rules as a version history per key.
   *
   * This is invariant I3 made visible. `CITY-BUS` carries v1 SUPERSEDED beside
   * v2 ACTIVE, so a ticket issued before the change can still name the policy
   * that priced it. A bureau reading only current rules would have no way to
   * explain last month's fare increase to a passenger who was charged the old
   * price — the exact dispute this system exists to settle.
   *
   * Rules with no operator are citywide policy and stay visible to every
   * scoped viewer: a zone fare applies to them whether or not it names an
   * operator, and hiding it would make their own pricing unexplainable.
   */
  async fares(staff: StaffPrincipal) {
    const scope = operatorScope(staff);
    const rules = await this.prisma.fareRule.findMany({
      where: scope ? { OR: [{ operatorId: scope }, { operatorId: null }] } : undefined,
      orderBy: [{ ruleKey: 'asc' }, { version: 'desc' }],
      select: {
        ruleKey: true,
        version: true,
        mode: true,
        status: true,
        originZone: true,
        destinationZone: true,
        baseFareFils: true,
        perKmFils: true,
        minimumFareFils: true,
        currency: true,
        effectiveFrom: true,
        effectiveUntil: true,
        changeReason: true,
        operatorId: true,
      },
    });

    const byKey = new Map<string, typeof rules>();
    for (const rule of rules) {
      const existing = byKey.get(rule.ruleKey);
      if (existing) {
        existing.push(rule);
      } else {
        byKey.set(rule.ruleKey, [rule]);
      }
    }

    return {
      groups: [...byKey.entries()].map(([ruleKey, versions]) => ({
        ruleKey,
        activeVersion: versions.find((v) => v.status === 'ACTIVE')?.version ?? null,
        versions: versions.map((v) => ({
          ...v,
          effectiveFrom: v.effectiveFrom?.toISOString() ?? null,
          effectiveUntil: v.effectiveUntil?.toISOString() ?? null,
        })),
      })),
      totals: {
        keys: byKey.size,
        active: rules.filter((r) => r.status === 'ACTIVE').length,
        draft: rules.filter((r) => r.status === 'DRAFT').length,
        pendingApproval: rules.filter((r) => r.status === 'PENDING_APPROVAL').length,
        superseded: rules.filter((r) => r.status === 'SUPERSEDED').length,
      },
    };
  }

  /** The fixed asset base: routes, stops, operators, and zone coverage. */
  async network(staff: StaffPrincipal) {
    return this.networkSnapshot(operatorScope(staff));
  }

  /** Ticket and journey volumes, split by status and mode. */
  async operations(staff: StaffPrincipal, range: DateRange) {
    const scope = operatorScope(staff);
    const where = await this.ticketWhere(range, scope);
    const [ticketTotals, byStatus, byMode, journeys] = await Promise.all([
      this.ticketTotals(range, scope),
      this.prisma.ticket.groupBy({
        by: ['status'],
        where,
        _count: { _all: true },
      }),
      this.prisma.ticket.groupBy({
        by: ['mode'],
        where,
        _count: { _all: true },
      }),
      this.journeyCount(range, scope),
    ]);

    return {
      range,
      tickets: {
        total: ticketTotals.total,
        issued: ticketTotals.issued,
        byStatus: byStatus.map((r) => ({ status: r.status, count: r._count._all })),
        byMode: byMode.map((r) => ({ mode: r.mode, count: r._count._all })),
      },
      journeys,
    };
  }

  /**
   * Account and ridership totals for a window.
   *
   * Lifecycle counts come from the account table and ridership from journeys
   * because they answer different questions: "how many citizens are registered"
   * is a standing fact, while "how many travelled this month" is a period
   * measure. Mixing them would make the sign-up count drift with the date
   * filter, which reads as a bug in a number that should not move.
   */
  private async passengerSnapshot(range: DateRange) {
    const [total, active, suspended, pending, verified, newInRange, byConcession, travelled] =
      await Promise.all([
        this.prisma.user.count(),
        this.prisma.user.count({ where: { status: 'ACTIVE' } }),
        this.prisma.user.count({ where: { status: 'SUSPENDED' } }),
        this.prisma.user.count({ where: { status: 'PENDING_VERIFICATION' } }),
        // phoneVerifiedAt is what actually proves a citizen owns the number.
        // Counting ACTIVE alone would overstate enrolment, because status
        // defaults independently of a completed OTP check.
        this.prisma.user.count({ where: { phoneVerifiedAt: { not: null } } }),
        this.prisma.user.count({
          where: { createdAt: { gte: range.from, lt: range.to } },
        }),
        this.prisma.concession.findMany({
          where: { isActive: true },
          orderBy: { code: 'asc' },
          select: {
            code: true,
            name: true,
            discountPercent: true,
            _count: { select: { passengers: true } },
          },
        }),
        this.prisma.journey.count({
          where: { createdAt: { gte: range.from, lt: range.to }, totalFareFils: { gt: 0 } },
        }),
      ]);

    return {
      accounts: {
        total,
        active,
        suspended,
        pending,
        phoneVerified: verified,
        newInRange,
      },
      journeysInRange: travelled,
      // Concessions are approved rather than self-declared, so "holders" counts
      // verified entitlements. It is the one personal dimension an eligibility
      // policy needs, and even here it is a number and never a list of people.
      concessions: byConcession.map((c) => ({
        code: c.code,
        name: c.name,
        discountPercent: c.discountPercent,
        holders: c._count.passengers,
      })),
    };
  }

  /**
   * Validates a caller-supplied payment status against the enum.
   *
   * Echoing the valid values costs nothing and turns a typo in a filter box
   * into a self-correcting request, instead of a silently empty table that
   * reads to an officer as "no payments happened".
   */
  private paymentStatus(raw: string): PaymentStatus {
    const candidate = raw.trim().toUpperCase();
    if (!Object.values(PaymentStatus).includes(candidate as PaymentStatus)) {
      throw new BadRequestException(
        `status must be one of: ${Object.values(PaymentStatus).join(', ')}`,
      );
    }
    return candidate as PaymentStatus;
  }

  /** Ridership and account totals. */
  async passengers(range: DateRange) {
    return this.passengerSnapshot(range);
  }

  /**
   * Daily settled revenue, zero-filled across the whole window.
   *
   * `generate_series` over the date range is what makes the chart honest. A
   * plain GROUP BY returns only days that have rows, so a day with no sales
   * would vanish from the axis and the line would jump the gap as though
   * nothing happened. The zero row IS the data: an officer must be able to see
   * that service stopped, not infer it from a straight segment.
   *
   * Sums are cast to bigint in SQL and converted here. Fils totals for any
   * realistic window sit far below 2^53, and letting a BigInt reach
   * JSON.stringify would throw on every single response.
   */
  private async dailyRevenue(range: DateRange, scope: string | null) {
    const rows = await this.prisma.$queryRaw<
      Array<{ day: Date; revenueFils: bigint; payments: bigint }>
    >(Prisma.sql`
      SELECT
        d.day::date AS day,
        COALESCE(
          SUM(p."amountFils") FILTER (WHERE p."status" = 'CONFIRMED'), 0
        )::bigint AS "revenueFils",
        COUNT(p.id) FILTER (WHERE p."status" = 'CONFIRMED')::bigint AS payments
      FROM generate_series(
        ${range.from}::date,
        (${range.to}::date - INTERVAL '1 day'),
        INTERVAL '1 day'
      ) AS d(day)
      LEFT JOIN "Payment" p
        ON p."createdAt" >= d.day
       AND p."createdAt" < d.day + INTERVAL '1 day'
       ${this.paymentOperatorFilter(scope)}
      GROUP BY d.day
      ORDER BY d.day
    `);

    return rows.map((r) => ({
      day: r.day.toISOString().slice(0, 10),
      revenueFils: Number(r.revenueFils),
      payments: Number(r.payments),
    }));
  }

  /** Daily planned journeys, zero-filled the same way. */
  private async dailyJourneys(range: DateRange, scope: string | null) {
    const rows = await this.prisma.$queryRaw<Array<{ day: Date; journeys: bigint }>>(
      Prisma.sql`
        SELECT d.day::date AS day, COUNT(j.id)::bigint AS journeys
        FROM generate_series(
          ${range.from}::date,
          (${range.to}::date - INTERVAL '1 day'),
          INTERVAL '1 day'
        ) AS d(day)
        LEFT JOIN "Journey" j
          ON j."createdAt" >= d.day
         AND j."createdAt" < d.day + INTERVAL '1 day'
         ${this.journeyOperatorFilter(scope)}
        GROUP BY d.day
        ORDER BY d.day
      `,
    );

    return rows.map((r) => ({
      day: r.day.toISOString().slice(0, 10),
      journeys: Number(r.journeys),
    }));
  }

  /**
   * SQL fragment restricting a Payment join to one operator's staff.
   *
   * The only operator link a Payment carries is the staff member who collected
   * it, so a scoped view is explicitly a view of assisted sales. Interpolated
   * as a parameter and cast to uuid rather than concatenated, so a caller
   * cannot alter the query through this value.
   */
  private paymentOperatorFilter(scope: string | null): Prisma.Sql {
    return scope === null
      ? Prisma.empty
      : Prisma.sql`AND p."collectedByStaffId" IN (
           SELECT s.id FROM "Staff" s WHERE s."operatorId" = ${scope}::uuid
         )`;
  }

  /** SQL fragment restricting a Journey join to routes run by one operator. */
  private journeyOperatorFilter(scope: string | null): Prisma.Sql {
    return scope === null
      ? Prisma.empty
      : Prisma.sql`AND EXISTS (
           SELECT 1 FROM "JourneyLeg" jl
           JOIN "Route" r ON r.id = jl."routeId"
           WHERE jl."journeyId" = j.id AND r."operatorId" = ${scope}::uuid
         )`;
  }

  /**
   * Payments in a window, optionally narrowed to a set of statuses.
   *
   * `createdAt` is used for the window rather than `confirmedAt` so the filter
   * means one consistent thing across every panel: payments *raised* in the
   * period. Mixing in confirmedAt would move money between periods depending on
   * which panel you looked at.
   */
  private paymentWhere(
    range: DateRange,
    scope: string | null,
    status?: PaymentStatus | PaymentStatus[],
  ): Prisma.PaymentWhereInput {
    return {
      createdAt: { gte: range.from, lt: range.to },
      ...(status ? { status: { in: Array.isArray(status) ? status : [status] } } : {}),
      ...(scope === null ? {} : { collectedByStaff: { operatorId: scope } }),
    };
  }

  /**
   * Tickets in a window, optionally narrowed to statuses and an operator.
   *
   * A ticket inherits its operator from either the trip it was issued against or
   * the route its journey planned over, so both paths are checked — a ticket
   * bought before boarding has a journey but no trip yet.
   */
  private async ticketWhere(
    range: DateRange,
    scope: string | null,
    statuses?: TicketStatus[],
  ): Promise<Prisma.TicketWhereInput> {
    const base: Prisma.TicketWhereInput = {
      createdAt: { gte: range.from, lt: range.to },
      ...(statuses && statuses.length > 0 ? { status: { in: statuses } } : {}),
    };
    if (scope === null) return base;

    const routes = await this.prisma.route.findMany({
      where: { operatorId: scope },
      select: { id: true },
    });
    const routeIds = routes.map((r) => r.id);

    return {
      ...base,
      OR: [
        { journey: { legs: { some: { routeId: { in: routeIds } } } } },
        { trip: { operatorId: scope } },
      ],
    };
  }

  /** Journeys in a window, optionally narrowed to an operator and a fare filter. */
  private async journeyWhere(
    range: DateRange,
    scope: string | null,
    fare?: { totalFareFils: { gt: number } },
  ): Promise<Prisma.JourneyWhereInput> {
    const base: Prisma.JourneyWhereInput = {
      createdAt: { gte: range.from, lt: range.to },
      ...(fare ?? {}),
    };
    if (scope === null) return base;

    const routes = await this.prisma.route.findMany({
      where: { operatorId: scope },
      select: { id: true },
    });
    return { ...base, legs: { some: { routeId: { in: routes.map((r) => r.id) } } } };
  }

  // —— Internals ———————————————————————————————————————————————————————————

  /**
   * Revenue position for a window.
   *
   * Four aggregates in one round trip rather than four sequential queries: a
   * dashboard refreshes on a timer, and query count dominates latency when each
   * figure is requested together anyway.
   */
  private async paymentTotals(range: DateRange, scope: string | null) {
    const [gross, confirmed, pending, refunded] = await Promise.all([
      this.prisma.payment.aggregate({
        where: this.paymentWhere(range, scope),
        _sum: { amountFils: true },
        _count: { _all: true },
      }),
      this.prisma.payment.aggregate({
        where: this.paymentWhere(range, scope, PaymentStatus.CONFIRMED),
        _sum: { amountFils: true },
        _count: { _all: true },
      }),
      this.prisma.payment.aggregate({
        where: this.paymentWhere(range, scope, [
          PaymentStatus.CREATED,
          PaymentStatus.PENDING,
          PaymentStatus.REQUIRES_ACTION,
          PaymentStatus.AUTHORIZED,
        ]),
        _sum: { amountFils: true },
        _count: { _all: true },
      }),
      this.prisma.payment.aggregate({
        where: this.paymentWhere(range, scope, [
          PaymentStatus.REFUNDED,
          PaymentStatus.PARTIALLY_REFUNDED,
          PaymentStatus.REVERSED,
        ]),
        _sum: { amountFils: true },
        _count: { _all: true },
      }),
    ]);

    return {
      grossFils: gross._sum.amountFils ?? 0,
      grossCount: gross._count._all,
      confirmedFils: confirmed._sum.amountFils ?? 0,
      confirmedCount: confirmed._count._all,
      pendingFils: pending._sum.amountFils ?? 0,
      pendingCount: pending._count._all,
      refundedFils: refunded._sum.amountFils ?? 0,
      refundedCount: refunded._count._all,
    };
  }

  /**
   * Ticket counts for a window.
   *
   * "Issued" means the ticket reached a state where a passenger holds a valid
   * fare document, not merely that a Ticket row exists. Counting CREATED rows as
   * ridership would report a passenger who abandoned checkout as a journey made.
   */
  private async ticketTotals(range: DateRange, scope: string | null) {
    const where = await this.ticketWhere(range, scope);
    const issuedWhere = await this.ticketWhere(range, scope, [
      TicketStatus.TICKET_ISSUED,
      TicketStatus.VALID,
      TicketStatus.VALIDATED,
      TicketStatus.COMPLETED,
    ]);
    const [total, issued] = await Promise.all([
      this.prisma.ticket.count({ where }),
      this.prisma.ticket.count({ where: issuedWhere }),
    ]);
    return { total, issued };
  }

  /**
   * Journey counts, split by whether a fare was actually quoted.
   *
   * A zero-fare journey is a real and useful category — a concession or a
   * transfer-discounted ride — so it is reported rather than dropped.
   */
  private async journeyCount(range: DateRange, scope: string | null) {
    const where = await this.journeyWhere(range, scope);
    const withFareWhere = await this.journeyWhere(range, scope, { totalFareFils: { gt: 0 } });
    const [total, withFare] = await Promise.all([
      this.prisma.journey.count({ where }),
      this.prisma.journey.count({ where: withFareWhere }),
    ]);
    return { total, withFare, zeroFare: total - withFare };
  }

  /**
   * Routes, stops, operators, and zone coverage.
   *
   * "Served" counts only stops an active route actually calls at. A stop nobody
   * serves is not part of the service, and a coverage figure that ignores
   * RouteStop would overstate the network precisely where it is weakest.
   */
  private async networkSnapshot(scope: string | null) {
    const routeWhere = scope ? { operatorId: scope } : undefined;

    const [routes, activeRoutes, stops, activeStops, servedStops, operators, byZone] =
      await Promise.all([
        this.prisma.route.count({ where: routeWhere }),
        this.prisma.route.count({ where: { ...routeWhere, isActive: true } }),
        this.prisma.stop.count(),
        this.prisma.stop.count({ where: { isActive: true } }),
        this.prisma.stop.count({
          where: { isActive: true, routeStops: { some: { route: routeWhere } } },
        }),
        this.prisma.operator.count(scope ? { where: { id: scope } } : undefined),
        this.prisma.stop.groupBy({
          by: ['zone'],
          where: { isActive: true },
          _count: { _all: true },
        }),
      ]);

    return {
      routes,
      activeRoutes,
      stops,
      activeStops,
      servedStops,
      // A gap an operator can act on, so it is surfaced rather than averaged away.
      unservedStops: Math.max(0, activeStops - servedStops),
      operators,
      stopsByZone: byZone
        .map((z) => ({ zone: z.zone ?? 'UNZONED', count: z._count._all }))
        .sort((a, b) => a.zone.localeCompare(b.zone)),
    };
  }
}
