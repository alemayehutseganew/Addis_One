/**
 * Staff self-service: shifts and enrolled devices.
 *
 * Mounted under /staff rather than /admin because none of this is
 * administration. An agent opening their own shift is doing their job, and
 * putting that behind the admin surface would suggest the same authority as
 * changing a fare rule, which it very obviously is not.
 *
 * Guarded by JwtAuthGuard AND StaffGuard, then by role. The variances list is
 * narrowed further to supervisors and administration, because cash shortfalls
 * are a supervisory matter and not every officer needs to see them.
 */

import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Post,
  UseGuards,
} from '@nestjs/common';
import {
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import {
  CurrentStaff,
  Roles,
  StaffGuard,
  StaffPrincipal,
} from '../auth/staff.guard';
import { PaymentsService } from '../payments/payments.service';
import { PrismaService } from '../../prisma/prisma.service';
import { JourneyPlannerService } from '../journeys/journey-planner.service';
import { IdentityService } from './identity.service';

// The role lists moved to policy.ts so that /auth/staff-session can declare the
// same answers these route guards enforce, instead of the two drifting apart.
import { RECONCILE_ROLES, SHIFT_ROLES } from '../auth/policy';

export class OpenShiftDto {
  /**
   * Cash placed in the drawer at open, in fils.
   *
   * Bounded below at zero: a negative float would invert the whole variance
   * calculation and turn a missing float into an apparent surplus.
   */
  @IsInt()
  @Min(0)
  openingCashFils!: number;

  @IsOptional()
  @IsUUID()
  vehicleId?: string;

  @IsOptional()
  @IsUUID()
  tripId?: string;
}

export class DeclareCashDto {
  /** What is physically in the drawer, in fils. */
  @IsInt()
  @Min(0)
  declaredCashFils!: number;
}

/**
 * A cash sale made by an officer on a passenger's behalf.
 *
 * The passenger and the journey may each be given two ways, and exactly one of
 * each pair is required.
 *
 * `passengerPhone` and `originStopId`/`destinationStopId` exist because the
 * original two UUID fields made this screen impossible to use: a conductor
 * standing on a bus cannot read a UUID off a passenger, and the journey UUID is
 * not printed anywhere they can reach. Naming a fare was never possible and
 * still is not — the server re-derives it either way, and `amountFils` is only
 * checked against the derived figure.
 *
 * `passengerUserId` and `journeyId` remain for a caller that has genuinely
 * resolved the account and the plan already.
 *
 * Neither `shiftId` nor `collectedByStaffId` is ever accepted from the client —
 * both come from the authenticated officer. Anything else would let one officer
 * file revenue against another officer's drawer.
 */
export class StaffSaleDto {
  @IsOptional()
  @IsUUID()
  passengerUserId?: string;

  @IsOptional()
  @IsString()
  @Length(7, 16)
  passengerPhone?: string;

  @IsOptional()
  @IsUUID()
  journeyId?: string;

  @IsOptional()
  @IsUUID()
  originStopId?: string;

  @IsOptional()
  @IsUUID()
  destinationStopId?: string;

  @IsInt()
  @Min(1)
  amountFils!: number;

  @IsString()
  @MinLength(8)
  @MaxLength(128)
  idempotencyKey!: string;
}

@Controller('staff')
@UseGuards(JwtAuthGuard, StaffGuard)
export class IdentityController {
  constructor(
    private readonly identity: IdentityService,
    // Used only for the cash-sale route, so the whole purchase - fare
    // re-derivation, payment state machine and I1 issuance - stays in one place.
    private readonly payments: PaymentsService,
    // Resolves the phone number a conductor can actually read into an account.
    private readonly prisma: PrismaService,
    // Prices the journey from two stops, so the sale does not need a journey id
    // the conductor has no way to obtain.
    private readonly planner: JourneyPlannerService,
  ) {}

  @Post('shifts/open')
  @Roles(...SHIFT_ROLES)
  openShift(@Body() dto: OpenShiftDto, @CurrentStaff() staff: StaffPrincipal) {
    return this.identity.openShift({
      staff,
      openingCashFils: dto.openingCashFils,
      vehicleId: dto.vehicleId ?? null,
      tripId: dto.tripId ?? null,
    });
  }

  @Get('shifts/mine')
  @Roles(...SHIFT_ROLES)
  myShift(@CurrentStaff() staff: StaffPrincipal) {
    return this.identity.myShift(staff);
  }

  /**
   * Close out a shift by declaring its cash.
   *
   * 201 because a declared shift is a new financial fact, not a view of an
   * existing one — the expected figure is recomputed and a variance may now
   * exist that did not before.
   */
  @Post('shifts/:id/declare')
  @Roles(...SHIFT_ROLES)
  declareCash(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: DeclareCashDto,
    @CurrentStaff() staff: StaffPrincipal,
  ) {
    return this.identity.declareCash(staff, id, dto.declaredCashFils);
  }

  @Get('shifts/variances')
  @Roles(...RECONCILE_ROLES)
  variances(@CurrentStaff() staff: StaffPrincipal) {
    return this.identity.variances(staff);
  }

  @Get('devices')
  @Roles(...SHIFT_ROLES)
  devices(@CurrentStaff() staff: StaffPrincipal) {
    return this.identity.devices(staff);
  }

  @Post('devices/:deviceId/enroll')
  @HttpCode(200)
  @Roles(...SHIFT_ROLES)
  enrollDevice(
    @Param('deviceId', ParseUUIDPipe) deviceId: string,
    @CurrentStaff() staff: StaffPrincipal,
  ) {
    return this.identity.enrollDevice(staff, deviceId);
  }

  /**
   * Turns the phone number a conductor can read into an account id.
   *
   * 404 rather than 400 when no such account exists: "that number is not
   * registered" is a lookup answer, and answering it for numbers that *are*
   * registered would turn this into an account-existence oracle.
   */
  private async resolvePassenger(phone?: string): Promise<string> {
    if (!phone) {
      throw new BadRequestException(
        'Give the passenger as a phone number or a user id',
      );
    }
    const user = await this.prisma.user.findUnique({ where: { phone } });
    if (!user) {
      throw new NotFoundException('No account for that phone number');
    }
    return user.id;
  }

  /**
   * Prices a journey from two stops the conductor picked from the stop list.
   *
   * The same planner the passenger app plans with, so an agent sale is priced by
   * the same rules, writes the same FareCalculation row and pins the same rule
   * version (I3) as one bought from a phone. The calculation is persisted rather
   * than quoted: the purchase below re-reads it to check the claimed amount, and
   * a fare that was never written down cannot be checked.
   *
   * Returns the persisted journey id, NOT `plan()[0].id`. That `id` is a
   * synthetic display label used to rank options for the UI — passing it to the
   * purchase reaches Prisma as a non-UUID and fails deep inside the query.
   */
  private async resolveJourney(
    originStopId: string | undefined,
    destinationStopId: string | undefined,
    userId: string,
  ): Promise<string> {
    if (!originStopId || !destinationStopId) {
      throw new BadRequestException(
        'Give a journey id, or both the origin and destination stops',
      );
    }
    const options = await this.planner.plan(
      originStopId,
      destinationStopId,
      new Date(),
      userId,
    );
    if (options.length === 0) {
      throw new NotFoundException('No route serves those two stops');
    }
    const journeyId = await this.planner.latestJourneyId(userId);
    if (!journeyId) {
      throw new NotFoundException('That journey could not be stored');
    }
    return journeyId;
  }

  /**
   * Records a cash sale against the calling officer's open shift.
   *
   * Delegates the whole purchase to PaymentsService rather than writing a ticket
   * directly. That is deliberate: it means cash goes through the same fare
   * re-derivation, the same payment state machine and the same I1 issuance gate
   * as a mobile payment. An agent sale that bypassed the orchestrator would be
   * revenue with no audit trail, and would be trivially forgeable.
   *
   * 201 when a ticket is issued; the response carries `ticket: null` if the
   * payment has not confirmed yet, which the officer must not present to the
   * passenger.
   */
  @Post('sales')
  @Roles(...SHIFT_ROLES)
  async sell(@Body() dto: StaffSaleDto, @CurrentStaff() staff: StaffPrincipal) {
    // Refused outright when no drawer is open — see requireOpenShift.
    const shift = await this.identity.requireOpenShift(staff);

    const passengerUserId =
      dto.passengerUserId ?? (await this.resolvePassenger(dto.passengerPhone));

    const journeyId = dto.journeyId
      ? dto.journeyId
      : await this.resolveJourney(
          dto.originStopId,
          dto.destinationStopId,
          passengerUserId,
        );

    const result = await this.payments.purchase({
      userId: passengerUserId,
      journeyId,
      claimedAmountFils: dto.amountFils,
      method: 'CASH',
      idempotencyKey: dto.idempotencyKey,
      // Taken from the authenticated officer and the open shift, never from the
      // body, so revenue cannot be filed against someone else's drawer.
      collectedByStaffId: staff.id,
      shiftId: shift.id,
    });

    return {
      ...result,
      // The shift reported is the one the PAYMENT belongs to, not the one that
      // happens to be open now. On an idempotent replay those differ, and echoing
      // the current shift would tell an officer their new drawer is holding a
      // sale recorded against an earlier one — which then fails to reconcile and
      // looks like missing money.
      shiftId: result.shiftId ?? shift.id,
      shiftReference: result.shiftId === null || result.shiftId === shift.id
        ? shift.reference
        : null,
    };
  }
}