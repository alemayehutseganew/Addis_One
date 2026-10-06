/**
 * Driver trip endpoints.
 *
 * Mounted under /driver rather than /mobility so the handheld's base URL reads as
 * the job being done. The roles here are the ones that actually drive; an
 * OPERATOR_ADMIN and a SUPERVISOR are included because dispatching on someone's
 * behalf is a real task, and the operator boundary in the service still applies
 * to them.
 */

import {
  Controller,
  Get,
  HttpCode,
  Param,
  ParseUUIDPipe,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { CurrentStaff, Roles, StaffGuard, StaffPrincipal } from '../auth/staff.guard';
import { MobilityService } from './mobility.service';

// The role list moved to policy.ts so that /auth/staff-session can declare the
// same answer this route guard enforces, instead of the two drifting apart.
import { DRIVER_ROLES } from '../auth/policy';

@Controller('driver')
@UseGuards(JwtAuthGuard, StaffGuard)
export class MobilityController {
  constructor(private readonly mobility: MobilityService) {}

  @Get('trips')
  @Roles(...DRIVER_ROLES)
  myTrips(@CurrentStaff() staff: StaffPrincipal, @Query('date') date?: string) {
    return this.mobility.myTrips(staff, date);
  }

  @Get('trips/:id/manifest')
  @Roles(...DRIVER_ROLES)
  manifest(
    @Param('id', ParseUUIDPipe) id: string,
    @CurrentStaff() staff: StaffPrincipal,
  ) {
    return this.mobility.manifest(staff, id);
  }

  @Post('trips/:id/start')
  @HttpCode(200)
  @Roles(...DRIVER_ROLES)
  start(
    @Param('id', ParseUUIDPipe) id: string,
    @CurrentStaff() staff: StaffPrincipal,
  ) {
    return this.mobility.startTrip(staff, id);
  }

  @Post('trips/:id/complete')
  @HttpCode(200)
  @Roles(...DRIVER_ROLES)
  complete(
    @Param('id', ParseUUIDPipe) id: string,
    @CurrentStaff() staff: StaffPrincipal,
  ) {
    return this.mobility.completeTrip(staff, id);
  }
}