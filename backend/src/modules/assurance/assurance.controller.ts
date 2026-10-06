/**
 * Complaint endpoints — filed by passengers, worked by staff.
 *
 * The one route here without StaffGuard is POST /complaints, and that is
 * deliberate rather than an oversight: a citizen has to be able to complain
 * without being staff. It is marked @Public so an anonymous caller still gets a
 * reference back, but the token is read when present so a signed-in passenger's
 * complaint is attached to them and appears in their history.
 *
 * Everything else sits behind JwtAuthGuard AND StaffGuard.
 */

import {
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { ComplaintCategory, ComplaintStatus } from '@prisma/client';
import {
  IsEnum,
  IsLatitude,
  IsLongitude,
  IsOptional,
  IsString,
  IsUUID,
  MaxLength,
  MinLength,
} from 'class-validator';
import { JwtAuthGuard, Public } from '../auth/jwt-auth.guard';
import {
  CurrentStaff,
  Roles,
  StaffGuard,
  StaffPrincipal,
} from '../auth/staff.guard';
import { AssuranceService } from './assurance.service';

// The role list moved to policy.ts so that /auth/staff-session can declare the
// same answer this route guard enforces, instead of the two drifting apart.
import { ASSURANCE_ROLES } from '../auth/policy';

export class FileComplaintDto {
  @IsEnum(ComplaintCategory)
  category!: ComplaintCategory;

  /**
   * Length-bounded at both ends. A floor keeps "no" from becoming a record that
   * wastes an officer's time; a ceiling keeps a pasted document from filling the
   * description column.
   */
  @IsString()
  @MinLength(10)
  @MaxLength(2000)
  description!: string;

  @IsOptional()
  @IsUUID()
  ticketId?: string;

  @IsOptional()
  @IsUUID()
  paymentId?: string;

  @IsOptional()
  @IsUUID()
  routeId?: string;

  @IsOptional()
  @IsLatitude()
  latitude?: number;

  @IsOptional()
  @IsLongitude()
  longitude?: number;
}

export class AdvanceComplaintDto {
  @IsEnum(ComplaintStatus)
  status!: ComplaintStatus;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  resolution?: string;
}

@Controller('complaints')
@UseGuards(JwtAuthGuard)
export class AssuranceController {
  constructor(private readonly assurance: AssuranceService) {}

  @Post()
  @Public()
  @HttpCode(201)
  file(@Body() dto: FileComplaintDto, @Req() req: { user?: { id?: string } }) {
    return this.assurance.file({
      userId: req.user?.id ?? null,
      category: dto.category,
      description: dto.description,
      ticketId: dto.ticketId ?? null,
      paymentId: dto.paymentId ?? null,
      routeId: dto.routeId ?? null,
      latitude: dto.latitude ?? null,
      longitude: dto.longitude ?? null,
    });
  }

  /** The signed-in caller's own complaints, whichever account they hold. */
  @Get('mine')
  mine(@Req() req: { user?: { id?: string } }) {
    return { complaints: req.user?.id ? this.assurance.mine(req.user.id) : [] };
  }

  @Get()
  @UseGuards(StaffGuard)
  @Roles(...ASSURANCE_ROLES)
  list(@CurrentStaff() staff: StaffPrincipal, @Query('status') status?: string) {
    return { complaints: this.assurance.list(staff, status) };
  }

  @Patch(':reference')
  @UseGuards(StaffGuard)
  @Roles(...ASSURANCE_ROLES)
  advance(
    @Param('reference') reference: string,
    @Body() dto: AdvanceComplaintDto,
    @CurrentStaff() staff: StaffPrincipal,
  ) {
    return this.assurance.advance(staff, reference, dto.status, dto.resolution);
  }
}