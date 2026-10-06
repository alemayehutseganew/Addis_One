import { Prisma } from '@prisma/client';
import {
  Controller,
  Get,
  Param,
  Query,
  UseGuards,
} from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { JwtAuthGuard, Public } from '../auth/jwt-auth.guard';

@Controller('vehicles')
@UseGuards(JwtAuthGuard)
@Public()
export class VehiclesController {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Looks up a vehicle by its QR code.
   *
   * The passenger scans a QR on the vehicle which encodes `vehicleCode` and
   * `vehicleId`. This endpoint validates the credential, checks the vehicle is
   * active and selling tickets, and returns the flat fare (or distance fare if
   * a boarding point is provided).
   */
  @Get('code/:code')
  async lookup(
    @Param('code') code: string,
    @Query('lat') latRaw?: string,
    @Query('lng') lngRaw?: string,
  ) {
    const vehicle = await this.prisma.vehicle.findUnique({
      where: { code },
      include: {
        operator: true,
      },
    });

    if (!vehicle) {
      return { vehicle: null };
    }

    if (vehicle.status !== 'ACTIVE') {
      return { vehicle: null };
    }

    // Check if vehicle has a valid QR credential
    const credential = await this.prisma.vehicleQrCredential.findFirst({
      where: {
        vehicleId: vehicle.id,
        revokedAt: null,
        expiresAt: { gt: new Date() },
      },
    });

    if (!credential) {
      return { vehicle: null };
    }

    // If boarding point provided, compute distance fare
    let fare = vehicle.fareFils;
    let fareBasis = 'flat';
    let distanceMeters = 0;
    let fromStopName: string | null = null;

    if (latRaw && lngRaw) {
      const lat = Number(latRaw);
      const lng = Number(lngRaw);
      if (Number.isFinite(lat) && Number.isFinite(lng)) {
        // Find nearest stop to the boarding point
        const nearby = await this.prisma.$queryRaw<
          Array<{ id: string; name: string; nameAm: string | null; latitude: number; longitude: number; distanceMeters: number }>
        >(Prisma.sql`
          SELECT * FROM (
            SELECT
              id,
              name,
              "nameAm",
              "latitude"::double precision AS latitude,
              "longitude"::double precision AS longitude,
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
          WHERE "distanceMeters" <= 500
          ORDER BY "distanceMeters" ASC
          LIMIT 1
        `);

        if (nearby.length > 0) {
          const stop = nearby[0];
          distanceMeters = Math.round(stop.distanceMeters);
          fromStopName = stop.name;
          fareBasis = 'distance';

          // Get fare rule for this vehicle's operator and mode
          const fareRule = await this.prisma.fareRule.findFirst({
            where: {
              operatorId: vehicle.operatorId,
              mode: vehicle.mode,
              status: 'ACTIVE',
            },
            orderBy: { version: 'desc' },
          });

          if (fareRule) {
            const distanceFareFils = Math.round(
              (distanceMeters / 1000) * Number(fareRule.perKmFils),
            );
            fare = fareRule.baseFareFils + distanceFareFils;
          }
        }
      }
    }

    return {
      vehicle: {
        id: vehicle.id,
        code: vehicle.code,
        operatorId: vehicle.operatorId,
        operatorName: vehicle.operator.name,
        mode: vehicle.mode,
        fareFils: fare,
        currency: 'ETB',
        fareBasis,
        distanceMeters,
        fromStopName,
        isPurchasable: true,
      },
    };
  }
}