/**
 * Ticket validation endpoints — the inspector's handheld.
 *
 * Separate module from ticketing because it is a different job: ticketing issues
 * and signs, validation verifies and records. The scanner never mints a ticket
 * and the issuer never validates one, so neither surface can drift into the
 * other's authority by accident.
 *
 * Guarded by JwtAuthGuard AND StaffGuard, then by role. An INSPECTOR is the
 * primary caller, but ticket officers, supervisors, conductors and agents all
 * stand at doors in practice, and the service additionally enforces the operator
 * boundary — a role grant alone does not make a scan legitimate.
 */

import {
  Body,
  Controller,
  Get,
  HttpCode,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  IsLatitude,
  IsLongitude,
  IsOptional,
  IsString,
  IsUUID,
  MaxLength,
  MinLength,
} from 'class-validator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import {
  CurrentStaff,
  Roles,
  StaffGuard,
  StaffPrincipal,
} from '../auth/staff.guard';
import { SCAN_ROLES } from '../auth/policy';
import { ValidationService } from './validation.service';

/**
 * The scanned QR string.
 *
 * Length-bounded on purpose. An inspector's camera produces a few hundred bytes,
 * so anything approaching this bound is not a ticket — and an unbounded string
 * would be written verbatim into an audit column. `whitelist` plus
 * `forbidNonWhitelisted` on the global pipe already stops extra fields being
 * smuggled through.
 */
export class ScanTicketDto {
  @IsString()
  @MinLength(20)
  @MaxLength(2048)
  qrString!: string;

  @IsOptional()
  @IsUUID()
  tripId?: string;

  @IsOptional()
  @IsUUID()
  deviceId?: string;

  @IsOptional()
  @IsLatitude()
  latitude?: number;

  @IsOptional()
  @IsLongitude()
  longitude?: number;
}

@Controller('validation')
@UseGuards(JwtAuthGuard, StaffGuard)
export class ValidationController {
  constructor(private readonly validation: ValidationService) {}

  /**
   * Validate a scanned ticket.
   *
   * Always 200, even for a rejection. The HTTP status answers "did the server
   * accept your request"; the `accepted` field answers "may this passenger
   * board". Collapsing the two would force a handheld to treat every invalid
   * ticket as a network error, and would fill the server log with 400s that
   * look like client faults when they are in fact successful fraud detections.
   *
   * 202 rather than 200 is not used for a different reason: nothing here is
   * deferred, and offline reconciliation is a separate, explicit endpoint.
   */
  @Post('scan')
  @HttpCode(200)
  @Roles(...SCAN_ROLES)
  scan(@Body() dto: ScanTicketDto, @CurrentStaff() staff: StaffPrincipal) {
    return this.validation.scan({
      qrString: dto.qrString,
      tripId: dto.tripId ?? null,
      deviceId: dto.deviceId ?? null,
      latitude: dto.latitude ?? null,
      longitude: dto.longitude ?? null,
      staff,
    });
  }

  /**
   * Recent validations by the caller, newest first.
   *
   * Scoped to the calling officer rather than the whole network on purpose: an
   * inspector's own scan history is what a handheld needs on a lost-device
   * review, and a network-wide feed of who inspected whom is surveillance data
   * with no operational use.
   */
  @Get('mine')
  @Roles(...SCAN_ROLES)
  async mine(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('take') take?: string,
  ) {
    const limit = Math.min(Math.max(Number(take) || 50, 1), 200);
    const rows = await this.validation.recentForStaff(staff.id, limit);
    return { validations: rows };
  }

  /** Kept so a future offline handhelds' clock drift can be reasoned about. */
  @Get('clock')
  @Roles(...SCAN_ROLES)
  clock() {
    return { serverTime: new Date().toISOString() };
  }
}