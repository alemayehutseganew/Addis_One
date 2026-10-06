import { Injectable } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { calculateFare, FareRuleRecord } from '../fares/fare-engine';

interface RouteStopNode {
  stopId: string;
  sequence: number;
  distanceFromStartMeters: number;
  stop: {
    id: string; code: string; name: string; nameAm: string | null; zone: string | null;
  };
}

interface LoadedRoute {
  id: string; code: string; name: string; operatorId: string; stops: RouteStopNode[];
}

export interface PlannedLeg {
  mode: 'BUS';
  routeId: string | null;
  routeCode: string | null;
  routeName: string | null;
  fromStopId: string;
  fromLabel: string;
  toStopId: string;
  toLabel: string;
  distanceMeters: number;
  durationSeconds: number;
  fareFils: number;
}

export interface PlannedJourneyResult {
  id: string;
  legs: PlannedLeg[];
  totalFareFils: number;
  /** Fils waived by the transfer rule. 0 on a direct journey. */
  transferDiscountFils: number;
  totalDurationSeconds: number;
  transferCount: number;
  /**
   * The fare rule that priced this option, so the persisted FareCalculation can
   * name the policy version (I3). Null when the engine found no rule.
   */
  anchor: {
    ruleId: string | null;
    ruleKey: string | null;
    ruleVersion: number | null;
  } | null;
  /** No live GPS feed is wired up, so timings are ESTIMATED, never REAL_TIME. */
  freshness: 'ESTIMATED';
}

const BOARD_SECONDS = 180;
const AVG_SPEED_KMH = 22;

@Injectable()
export class JourneyPlannerService {
  /**
   * Percent of a second leg the passenger pays, loaded from the active
   * TransferRule. `undefined` until first read, which is what lets the lazy
   * fallback in `transferRetainedPercent` distinguish "not loaded yet" from a
   * legitimate 100 (no discount).
   */
  private cachedRetainedPercent: number | undefined;

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Plans itineraries between two stops.
   *
   * Deliberately simple and explainable rather than clever: a direct ride on any
   * route serving both stops, plus one transfer via a shared interchange. When a
   * passenger disputes a fare they can be shown *why* the option existed; an
   * opaque algorithm cannot be explained at all.
   *
   * Fares come from the shared fare engine — never recomputed here — so quoting
   * rules have exactly one implementation.
   *
   * When a userId is supplied the chosen option is PERSISTED as a Journey plus
   * a FareCalculation. That is not a convenience: the purchase endpoint
   * re-reads the stored calculation to verify the amount the passenger paid
   * (revenue protection), and the ticket pins the rule version from it (I3).
   * A quote that is never written down cannot be checked.
   */
  async plan(
    originStopId: string,
    destinationStopId: string,
    departureTime: Date,
    userId?: string,
  ): Promise<PlannedJourneyResult[]> {
    const [origin, destination] = await Promise.all([
      this.prisma.stop.findUnique({ where: { id: originStopId } }),
      this.prisma.stop.findUnique({ where: { id: destinationStopId } }),
    ]);
    if (!origin || !destination) return [];
    if (originStopId === destinationStopId) return [];

    const routes = await this.loadRoutes();
    const rules = await this.loadFareRules();
    await this.loadTransferRule();
    const out: PlannedJourneyResult[] = [];

    for (const route of routes) {
      const boardIdx = route.stops.findIndex((s) => s.stopId === originStopId);
      const alightIdx = route.stops.findIndex((s) => s.stopId === destinationStopId);
      if (boardIdx < 0 || alightIdx < 0) continue;
      // Routes run both ways; only the correct direction serves the passenger.
      if (alightIdx <= boardIdx) continue;

      const rideMeters =
        route.stops[alightIdx].distanceFromStartMeters -
        route.stops[boardIdx].distanceFromStartMeters;

      const fare = calculateFare(rules, {
        mode: 'BUS', routeId: route.id, operatorId: route.operatorId,
        originZone: origin.zone, destinationZone: destination.zone,
        distanceMeters: rideMeters, at: departureTime,
      });

      out.push({
        id: `direct-${route.code}`,
        legs: [this.leg(route, originStopId, origin.name,
          destinationStopId, destination.name, rideMeters, fare.totalFareFils)],
        totalFareFils: fare.totalFareFils,
        transferDiscountFils: 0,
        totalDurationSeconds: this.rideSeconds(rideMeters),
        transferCount: 0,
        anchor: {
          ruleId: fare.ruleId,
          ruleKey: fare.ruleKey,
          ruleVersion: fare.ruleVersion,
        },
        freshness: 'ESTIMATED',
      });
    }


    // ── One transfer, via an interchange served by two routes ────────────────
    const seen = new Set<string>();
    for (const first of routes) {
      const firstIdx = first.stops.findIndex((s) => s.stopId === originStopId);
      if (firstIdx < 0) continue;

      for (const second of routes) {
        if (second.id === first.id) continue;
        const secondIdx = second.stops.findIndex((s) => s.stopId === destinationStopId);
        if (secondIdx < 0) continue;

        // The interchange must sit after boarding on route 1 and before
        // alighting on route 2, or the itinerary is not actually usable.
        const xfer = second.stops.find((s) => {
          if (s.stopId === originStopId || s.stopId === destinationStopId) return false;
          if (s.sequence >= secondIdx) return false;
          const onFirst = first.stops.find((f) => f.stopId === s.stopId);
          return !!onFirst && onFirst.sequence > firstIdx;
        });
        if (!xfer) continue;

        const onFirst = first.stops.find((f) => f.stopId === xfer.stopId)!;
        const leg1Meters =
          xfer.distanceFromStartMeters - first.stops[firstIdx].distanceFromStartMeters;
        const leg2Meters =
          second.stops[secondIdx].distanceFromStartMeters - xfer.distanceFromStartMeters;

        const fare1 = calculateFare(rules, {
          mode: 'BUS', routeId: first.id, operatorId: first.operatorId,
          originZone: origin.zone, destinationZone: xfer.stop.zone,
          distanceMeters: leg1Meters, at: departureTime,
        });
        const fare2 = calculateFare(rules, {
          mode: 'BUS', routeId: second.id, operatorId: second.operatorId,
          originZone: xfer.stop.zone, destinationZone: destination.zone,
          distanceMeters: leg2Meters, at: departureTime,
        });

        const key = `${first.code}->${second.code}@${xfer.stop.code}`;
        if (seen.has(key)) continue;
        seen.add(key);

        // ── Transfer discount ────────────────────────────────────────────────
        // Pricing both legs at full fare makes a one-change trip cost far more
        // The bureau's rule discounts the SECOND leg. The saving is reported
        // separately so it is auditable rather than silently folded into the
        // total, and so the FareCalculation can record what was waived.
        const transferSaving = this.transferSaving(fare2.totalFareFils);
        const leg2Fare = fare2.totalFareFils - transferSaving;

        out.push({
          id: `transfer-${key}`,
          legs: [
            this.leg(first, originStopId, origin.name,
              xfer.stopId, xfer.stop.name, leg1Meters, fare1.totalFareFils),
            this.leg(second, xfer.stopId, xfer.stop.name,
              destinationStopId, destination.name, leg2Meters, leg2Fare),
          ],
          totalFareFils: fare1.totalFareFils + leg2Fare,
          transferDiscountFils: transferSaving,
          totalDurationSeconds:
            this.rideSeconds(leg1Meters) + this.rideSeconds(leg2Meters) + BOARD_SECONDS,
          transferCount: 1,
          // The first leg anchors the rule version: it is the one that set the
          // starting price, and the second is a derivative of it.
          anchor: {
            ruleId: fare1.ruleId,
            ruleKey: fare1.ruleKey,
            ruleVersion: fare1.ruleVersion,
          },
          freshness: 'ESTIMATED',
        });
      }
    }

    const ranked = this.rank(out);
    if (userId && ranked.length > 0) {
      await this.persistJourney(userId, origin, destination, departureTime, ranked[0]);
    }
    return ranked;
  }

  /**
   * Planned journeys for a passenger, newest first.
   *
   * Read here rather than in the controller so this class keeps no database
   * handle: the controller is a transport layer, the planner owns the data.
   */
  async journeysForUser(userId: string) {
    return this.prisma.journey.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: 50,
      include: { ticket: true },
    });
  }

  /**
   * The id of the journey most recently persisted for this user.
   *
   * Read back rather than returned from `persistJourney` so the controller can
   * stay a pure transport layer. The plan call and this lookup are separate
   * statements rather than one transaction: a read that follows its own write
   * in the same transaction can see it under READ COMMITTED, but keeping them
   * apart means a failed read cannot roll back a successful plan.
   */
  async latestJourneyId(userId: string | undefined): Promise<string | null> {
    if (!userId) return null;
    const row = await this.prisma.journey.findFirst({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      select: { id: true },
    });
    return row?.id ?? null;
  }

  /**
   * Writes the passenger's chosen option as a Journey with a FareCalculation.
   *
   * Only the best-ranked option is stored. The alternatives were quotes the
   * passenger declined, and persisting every search would make the audit trail
   * unreadable without adding anything the settlement reports need.
   */
  private async persistJourney(
    userId: string,
    origin: { latitude: unknown; longitude: unknown; name: string; zone: string | null },
    destination: { latitude: unknown; longitude: unknown; name: string; zone: string | null },
    departureTime: Date,
    chosen: PlannedJourneyResult,
  ): Promise<void> {
    const totalDistance = chosen.legs.reduce((sum, l) => sum + l.distanceMeters, 0);
    const anchor = chosen.anchor;

    // Two explicit writes rather than a nested create: the calculation needs
    // the journey's generated id, and this keeps the order explicit.
    const journey = await this.prisma.journey.create({
      data: {
        userId,
        originLat: origin.latitude as never,
        originLng: origin.longitude as never,
        originLabel: origin.name,
        destLat: destination.latitude as never,
        destLng: destination.longitude as never,
        destLabel: destination.name,
        departureTime,
        totalFareFils: chosen.totalFareFils,
        totalDurationSeconds: chosen.totalDurationSeconds,
        walkingMeters: 0,
        transferCount: chosen.transferCount,
        expiresAt: new Date(Date.now() + 30 * 60_000),
      },
    });

    await this.prisma.fareCalculation.create({
      data: {
        journeyId: journey.id,
        fareRuleId: anchor?.ruleId ?? null,
        // I3: name the exact policy version that priced this journey, so a
        // future fare change cannot rewrite what the passenger agreed to.
        ruleKey: anchor?.ruleKey ?? null,
        ruleVersion: anchor?.ruleVersion ?? null,
        mode: 'BUS',
        originZone: origin.zone,
        destinationZone: destination.zone,
        distanceMeters: totalDistance,
        baseFareFils: chosen.totalFareFils,
        totalFareFils: chosen.totalFareFils,
        currency: 'ETB',
        transferDiscountFils: chosen.transferDiscountFils,
        expiresAt: new Date(Date.now() + 30 * 60_000),
      },
    });
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  private leg(
    route: LoadedRoute,
    fromStopId: string,
    fromLabel: string,
    toStopId: string,
    toLabel: string,
    distanceMeters: number,
    fareFils: number,
  ): PlannedLeg {
    return {
      mode: 'BUS',
      routeId: route.id,
      routeCode: route.code,
      routeName: route.name,
      fromStopId,
      fromLabel,
      toStopId,
      toLabel,
      distanceMeters,
      durationSeconds: this.rideSeconds(distanceMeters),
      fareFils,
    };
  }

  private rideSeconds(meters: number): number {
    return Math.round((meters / 1000 / AVG_SPEED_KMH) * 3600) + BOARD_SECONDS;
  }

  /**
   * Fils waived on the second leg of a one-change journey.
   *
   * `TransferRule.discountPercent` is the percent the passenger RETAINS — the
   * seed's `STD-TRANSFER` is 80, meaning the second leg is billed at 80% of its
   * full fare. Reading it as a discount would bill 160%.
   *
   * The discount is bounded to the second leg: folding it into the total would
   * hide what was paid per leg, and discounting the first would reward splitting
   * a trip unnecessarily.
   */
  private transferSaving(secondLegFareFils: number): number {
    const retained = this.transferRetainedPercent();
    if (retained >= 100 || retained < 0) return 0;
    return Math.round((secondLegFareFils * (100 - retained)) / 100);
  }

  /**
   * Percent of the second leg the passenger pays, read from the active
   * transfer rule.
   *
   * Cached for the process lifetime: fare policy is versioned and audited, so
   * a change is expected to arrive with a restart rather than silently at
   * midday. A missing or deactivated rule means no discount — paying full fare
   * is the safe failure, never a free ride.
   */
  private transferRetainedPercent(): number {
    return this.cachedRetainedPercent ?? 100;
  }

  /**
   * Cheapest first, then fastest.
   *
   * Ordering by price matches what a commuter in Addis Ababa is usually
   * optimising for; duration breaks ties so the cheapest direct run is
   * preferred over a cheaper but slower transfer.
   */
  private rank(journeys: PlannedJourneyResult[]): PlannedJourneyResult[] {
    return [...journeys].sort(
      (a, b) =>
        a.totalFareFils - b.totalFareFils ||
        a.totalDurationSeconds - b.totalDurationSeconds,
    );
  }

  private async loadRoutes(): Promise<LoadedRoute[]> {
    const rows = await this.prisma.route.findMany({
      where: { isActive: true, mode: 'BUS' },
      include: {
        stops: {
          orderBy: { sequence: 'asc' },
          include: { stop: true },
        },
      },
    });

    return rows.map((r) => ({
      id: r.id,
      code: r.code,
      name: r.name,
      operatorId: r.operatorId,
      stops: r.stops.map((s) => ({
        stopId: s.stopId,
        sequence: s.sequence,
        distanceFromStartMeters: s.distanceFromStartMeters,
        stop: {
          id: s.stop.id,
          code: s.stop.code,
          name: s.stop.name,
          nameAm: s.stop.nameAm,
          zone: s.stop.zone,
        },
      })),
    }));
  }

  /**
   * Loads the transfer discount the passenger RETAINS on a second leg.
   *
   * Only a rule that is active, currently in effect, and covers BUS is accepted.
   * Anything else leaves the discount off, so a passenger pays full fare rather
   * than the system guessing at a concession it cannot justify.
   */
  private async loadTransferRule(): Promise<void> {
    const now = new Date();
    const rule = await this.prisma.transferRule.findFirst({
      where: {
        isActive: true,
        effectiveFrom: { lte: now },
        appliesToModes: { has: 'BUS' },
        maxTransfers: { gte: 1 },
      },
      orderBy: { effectiveFrom: 'desc' },
    });

    this.cachedRetainedPercent = rule ? rule.discountPercent : 100;
  }

  /**
   * Loads fare rules in the shape the engine expects.
   *
   * Only ACTIVE rules are loaded: the engine's `isRuleInEffect` would filter
   * them anyway, and excluding superseded rows at the source makes the intent
   * obvious at the call site.
   */
  private async loadFareRules(): Promise<FareRuleRecord[]> {
    const rows = await this.prisma.fareRule.findMany({
      where: { status: 'ACTIVE' },
    });

    return rows.map((r) => ({
      id: r.id,
      ruleKey: r.ruleKey,
      version: r.version,
      mode: r.mode,
      routeId: r.routeId,
      operatorId: r.operatorId,
      originZone: r.originZone,
      destinationZone: r.destinationZone,
      distanceFromMeters: r.distanceFromMeters,
      distanceToMeters: r.distanceToMeters,
      baseFareFils: r.baseFareFils,
      perKmFils: r.perKmFils,
      minimumFareFils: r.minimumFareFils,
      currency: r.currency,
      status: r.status,
      effectiveFrom: r.effectiveFrom,
      effectiveUntil: r.effectiveUntil,
    }));
  }
}

