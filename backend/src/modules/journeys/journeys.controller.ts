import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Param,
  ParseUUIDPipe,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { IsOptional, IsISO8601, IsString, IsUUID, MinLength } from 'class-validator';
import { Prisma } from '@prisma/client';
import { JwtAuthGuard, Public } from '../auth/jwt-auth.guard';
import { PrismaService } from '../../prisma/prisma.service';
import { JourneyPlannerService } from './journey-planner.service';

class PlanJourneyDto {
  @IsUUID()
  originStopId!: string;

  @IsUUID()
  destinationStopId!: string;

  @IsOptional()
  @IsISO8601()
  departureTime?: string;
}

/** Stop search, used by the journey planner's destination picker. */
@Controller('stops')
@UseGuards(JwtAuthGuard)
@Public()
export class StopsController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  async search(@Query('q') q = '') {
    const term = q.trim();

    // An empty query is a browse, not a search: return the busiest stops so the
    // picker is not an empty box.
    const rows = term
      ? await this.prisma.stop.findMany({
          where: {
            isActive: true,
            OR: [
              { name: { contains: term, mode: 'insensitive' } },
              { nameAm: { contains: term } },
              { code: { contains: term, mode: 'insensitive' } },
            ],
          },
          take: 25,
          orderBy: { name: 'asc' },
        })
      : await this.prisma.stop.findMany({
          where: { isActive: true },
          take: 25,
          orderBy: { name: 'asc' },
        });

    return {
      stops: rows.map((s) => ({
        id: s.id,
        code: s.code,
        name: s.name,
        nameAm: s.nameAm,
        latitude: Number(s.latitude),
        longitude: Number(s.longitude),
        zone: s.zone,
        kind: 'stop',
      })),
    };
  }

  /**
   * Stops nearest a position, with their real distance.
   *
   * This exists because the client cannot do this job. `GET /stops` returns at
   * most 25 rows ordered by name, so a nearest-stop search on the device would
   * rank whichever 25 stops happened to sort near "A" and ignore the several
   * hundred that are actually closest. Snapping a passenger to the origin of the
   * alphabet instead of the stop they are standing at is a wrong answer, not an
   * approximate one, so the ranking happens here where every stop is visible.
   *
   * Distance is great-circle metres on a spherical earth. At city scale the
   * error against WGS-84 ellipsoids is well under a metre, which is far below
   * the precision of a phone GPS fix and irrelevant next to the size of a stop.
   */
  @Get('nearby')
  async nearby(
    @Query('lat') latRaw?: string,
    @Query('lng') lngRaw?: string,
    @Query('limit') limitRaw?: string,
    @Query('radiusMeters') radiusRaw?: string,
  ) {
    const lat = Number(latRaw);
    const lng = Number(lngRaw);

    // Parsed explicitly rather than through a DTO: these arrive as strings, and
    // Number('') is 0, which is a valid coordinate in the Gulf of Guinea. An
    // absent or empty parameter has to be rejected, not silently read as 0,0.
    if (latRaw === undefined || latRaw.trim() === '' || !Number.isFinite(lat)) {
      throw new BadRequestException('lat is required');
    }
    if (lat < -90 || lat > 90) {
      throw new BadRequestException('lat must be between -90 and 90');
    }
    if (lngRaw === undefined || lngRaw.trim() === '' || !Number.isFinite(lng)) {
      throw new BadRequestException('lng is required');
    }
    if (lng < -180 || lng > 180) {
      throw new BadRequestException('lng must be between -180 and 180');
    }

    // Clamped so a caller cannot ask for the whole network in one response.
    const requested = Number(limitRaw);
    const limit =
      Number.isFinite(requested) && requested > 0
        ? Math.min(Math.floor(requested), 10)
        : 5;

    // A radius is mandatory, not optional. Without one, a fix from anywhere on
    // earth resolves to the globally nearest stop and the app presents it as the
    // passenger's location: a point in Delhi was served "Bole, 4,253,742 m", a
    // stop in another country 4,000 km away. A confidently wrong origin is worse
    // than no origin, so anything beyond walking range returns an empty list and
    // the client can say so.
    //
    // Two kilometres is a generous walk to a stop; the ceiling stops a caller
    // from opting out of the check to get a "nearest" stop on the other side of
    // the country.
    const DEFAULT_RADIUS_METERS = 2000;
    const MAX_RADIUS_METERS = 5000;
    const requestedRadius = Number(radiusRaw);
    const radiusMeters =
      Number.isFinite(requestedRadius) && requestedRadius > 0
        ? Math.min(Math.floor(requestedRadius), MAX_RADIUS_METERS)
        : DEFAULT_RADIUS_METERS;

    const rows = await this.prisma.$queryRaw<
      Array<{
        id: string;
        code: string;
        name: string;
        nameAm: string | null;
        latitude: number;
        longitude: number;
        zone: string | null;
        distanceMeters: number;
      }>
    >(Prisma.sql`
      SELECT * FROM (
        SELECT
          id,
          code,
          name,
          "nameAm",
          "latitude"::double precision AS latitude,
          "longitude"::double precision AS longitude,
          zone,
          (
            6371000 * 2 * asin(sqrt(
              power(sin(radians("latitude"::double precision - ${lat}) / 2), 2)
              + cos(radians(${lat})) * cos(radians("latitude"::double precision))
              * power(sin(radians("longitude"::double precision - ${lng}) / 2), 2)
            ))
          )::double precision AS "distanceMeters"
        FROM "Stop"
        WHERE "isActive" = true
      ) AS ranked
      WHERE "distanceMeters" <= ${radiusMeters}
      ORDER BY "distanceMeters" ASC
      LIMIT ${limit}
    `);

    return {
      origin: { latitude: lat, longitude: lng },
      // Echoed so the client can tell "you are outside the area we serve" apart
      // from "the search came back empty", and can word the message honestly.
      radiusMeters,
      stops: rows.map((s) => ({
        id: s.id,
        code: s.code,
        name: s.name,
        nameAm: s.nameAm,
        latitude: s.latitude,
        longitude: s.longitude,
        zone: s.zone,
        kind: 'stop',
        distanceMeters: Math.round(s.distanceMeters),
      })),
    };
  }
}

@Controller('journeys')
@UseGuards(JwtAuthGuard)
export class JourneysController {
  constructor(private readonly planner: JourneyPlannerService) {}

  /**
   * Plans itineraries. Fares in the response are server-computed and final for
   * planning purposes — the quote is re-derived and pinned at purchase time.
   *
   * The plan is persisted against the signed-in user so a purchase can be
   * checked against it later; an anonymous plan would be unverifiable.
   *
   * The first (best-ranked) option carries the `journeyId` of its stored quote.
   * The client needs that id to start a payment: the purchase endpoint verifies
   * the claimed amount against the FareCalculation attached to that journey, so
   * without it there is nothing to purchase against.
   */
  @Post('plan')
  @Public()
  async plan(@Body() dto: PlanJourneyDto, @Req() req: any) {
    const departure = dto.departureTime
      ? new Date(dto.departureTime)
      : new Date();

    const userId: string | undefined = req.user?.id;
    const journeys = await this.planner.plan(
      dto.originStopId,
      dto.destinationStopId,
      departure,
      userId,
    );

    // The planner persists the best-ranked option; its id is what the client
    // must send back to buy, because the purchase endpoint verifies the claimed
    // amount against the FareCalculation attached to that journey.
    const storedId = journeys.length
      ? await this.planner.latestJourneyId(userId)
      : null;

    return {
      journeys: journeys.map((j, index) => ({
        id: j.id,
        legs: j.legs.map((l, i) => ({
          sequence: i,
          mode: l.mode,
          routeId: l.routeId,
          routeCode: l.routeCode,
          routeName: l.routeName,
          fromLabel: l.fromLabel,
          toLabel: l.toLabel,
          distanceMeters: l.distanceMeters,
          durationSeconds: l.durationSeconds,
          fareFils: l.fareFils,
        })),
        totalFareFils: j.totalFareFils,
        /** Fils waived by the transfer rule; 0 on a direct journey. */
        transferDiscountFils: j.transferDiscountFils,
        totalDurationSeconds: j.totalDurationSeconds,
        walkingMeters: 0,
        transferCount: j.transferCount,
        freshness: j.freshness,
        // Only the persisted (best-ranked) option is purchasable. The others
        // were quotes the passenger declined and have no stored fare to verify
        // a payment against, so the client must re-plan to buy one.
        journeyId: index === 0 ? storedId : null,
      })),
    };
  }

  /**
   * The signed-in passenger's planned journeys, newest first.
   *
   * This is trip history, distinct from /tickets/mine: a journey is a plan the
   * passenger made, and most of them are never bought. Showing only tickets
   * would hide every search that did not lead to a purchase.
   *
   * Public so a signed-out passenger gets "sign in to see your trips" rather
   * than a bare 401. Identity is still required for actual content — the handler
   * returns an empty, explicitly-flagged list when `req.user` is absent.
   */
  @Get('mine')
  @Public()
  async mine(@Req() req: any) {
    const userId: string | undefined = req.user?.id;
    if (!userId) {
      // Reachable but not identifiable. The guard allows this through so a
      // signed-out caller still sees a usable message instead of a bare 401.
      return { journeys: [], signedIn: false };
    }

    const rows = await this.planner.journeysForUser(userId);

    return {
      signedIn: true,
      journeys: rows.map((j) => ({
        id: j.id,
        originLabel: j.originLabel,
        destinationLabel: j.destLabel,
        departureTime: j.departureTime,
        totalFareFils: j.totalFareFils,
        totalDurationSeconds: j.totalDurationSeconds,
        transferCount: j.transferCount,
        createdAt: j.createdAt,
        // Lets the app distinguish "planned" from "travelled" without joining
        // the ticket table on the client.
        ticketId: j.ticket?.id ?? null,
        ticketReference: j.ticket?.reference ?? null,
      })),
    };
  }
}
