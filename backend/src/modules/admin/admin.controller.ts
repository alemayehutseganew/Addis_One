import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  Put,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  CreateRouteInput,
  CreateStopInput,
  CreateVehicleInput,
  ReviseFareRuleInput,
  AdminService,
  UpdateRouteInput,
  UpdateStaffInput,
  UpdateStopInput,
  UpdateVehicleInput,
} from './admin.service';
import {
  CurrentStaff,
  Roles,
  StaffGuard,
  StaffPrincipal,
} from '../auth/staff.guard';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import {
  ADMIN_ROLES,
  FARE_APPROVAL_ROLES,
  FARE_AUTHOR_ROLES,
  STAFF_MANAGEMENT_ROLES,
} from '../auth/policy';

/**
 * Write-side administration.
 *
 * Separate from DashboardController rather than bolted onto it, because that
 * controller is read-only by design: mixing approval and editing into a
 * reporting surface would put unreviewed writes behind a screen whose guards were
 * only ever reasoned about for reads.
 *
 * Every route sits behind JwtAuthGuard AND StaffGuard, in that order. The
 * operator boundary is enforced in the service via `assertOperator` rather than
 * by role alone, so an OPERATOR_ADMIN editing their own fleet is filtered by data
 * ownership and not just by which buttons the UI shows.
 */
@Controller('admin')
@UseGuards(JwtAuthGuard, StaffGuard)
@Roles(...ADMIN_ROLES)
export class AdminController {
  constructor(private readonly admin: AdminService) {}

  // ── Stops ──────────────────────────────────────────────────────────────────

  @Get('stops')
  listStops(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('includeInactive') includeInactive?: string,
  ) {
    return this.admin.listStops(staff, includeInactive === 'true');
  }

  @Post('stops')
  createStop(@CurrentStaff() staff: StaffPrincipal, @Body() input: CreateStopInput) {
    return this.admin.createStop(staff, input);
  }

  @Patch('stops/:id')
  updateStop(
    @CurrentStaff() staff: StaffPrincipal,
    @Param('id') id: string,
    @Body() input: UpdateStopInput,
  ) {
    return this.admin.updateStop(staff, id, input);
  }

  @Put('stops/:id/active')
  setStopActive(
    @CurrentStaff() staff: StaffPrincipal,
    @Param('id') id: string,
    @Body() body: { isActive: boolean },
  ) {
    return this.admin.setStopActive(staff, id, body.isActive);
  }

  // ── Vehicles ───────────────────────────────────────────────────────────────

  @Get('vehicles')
  listVehicles(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('includeInactive') includeInactive?: string,
  ) {
    return this.admin.listVehicles(staff, includeInactive === 'true');
  }

  @Post('vehicles')
  createVehicle(@CurrentStaff() staff: StaffPrincipal, @Body() input: CreateVehicleInput) {
    return this.admin.createVehicle(staff, input);
  }

  @Patch('vehicles/:id')
  updateVehicle(
    @CurrentStaff() staff: StaffPrincipal,
    @Param('id') id: string,
    @Body() input: UpdateVehicleInput,
  ) {
    return this.admin.updateVehicle(staff, id, input);
  }

  // ── Routes ─────────────────────────────────────────────────────────────────

  @Get('routes')
  listRoutes(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('includeInactive') includeInactive?: string,
  ) {
    return this.admin.listRoutes(staff, includeInactive === 'true');
  }

  @Post('routes')
  createRoute(@CurrentStaff() staff: StaffPrincipal, @Body() input: CreateRouteInput) {
    return this.admin.createRoute(staff, input);
  }

  @Patch('routes/:id')
  updateRoute(
    @CurrentStaff() staff: StaffPrincipal,
    @Param('id') id: string,
    @Body() input: UpdateRouteInput,
  ) {
    return this.admin.updateRoute(staff, id, input);
  }

  @Put('routes/:id/stops')
  setRouteStops(
    @CurrentStaff() staff: StaffPrincipal,
    @Param('id') id: string,
    @Body() body: { stops: Array<{ stopId: string; sequence: number }> },
  ) {
    return this.admin.setRouteStops(staff, id, body.stops ?? []);
  }
// ── Fare rules ──────────────────────────────────────────────────────────────

  /**
   * Drafting a fare and approving one are separate endpoints with separate role
   * lists. Read access is broader than either: an auditor should be able to see
   * the full version history without being able to change it.
   */
  @Get('fare-rules')
  listFareRules(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('ruleKey') ruleKey?: string,
  ) {
    return this.admin.listFareRules(staff, ruleKey);
  }

  @Post('fare-rules')
  @Roles(...FARE_AUTHOR_ROLES)
  reviseFareRule(@CurrentStaff() staff: StaffPrincipal, @Body() input: ReviseFareRuleInput) {
    return this.admin.reviseFareRule(staff, input);
  }

  @Post('fare-rules/:id/activate')
  @Roles(...FARE_APPROVAL_ROLES)
  activateFareRule(@CurrentStaff() staff: StaffPrincipal, @Param('id') id: string) {
    return this.admin.activateFareRule(staff, id);
  }

  /**
   * Operator choices for the route, vehicle and staff dropdowns.
   *
   * Names and codes only — no licence numbers or settlement accounts, which are
   * commercial data a forms dropdown has no business carrying around.
   */
  @Get('operators')
  listOperators() {
    return this.admin.listOperators();
  }

  // ── Staff ──────────────────────────────────────────────────────────────────

  @Get('staff')
  listStaff(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('includeInactive') includeInactive?: string,
  ) {
    return this.admin.listStaff(staff, includeInactive === 'true');
  }

  /**
   * Changing someone's role is the single highest-impact action available here,
   * so it is restricted to the bureau rather than to operator admins — an
   * operator admin managing their own roster does not need to mint supervisors.
   */
  @Patch('staff/:id')
  @Roles(...STAFF_MANAGEMENT_ROLES)
  updateStaff(
    @CurrentStaff() staff: StaffPrincipal,
    @Param('id') id: string,
    @Body() input: UpdateStaffInput,
  ) {
    return this.admin.updateStaff(staff, id, input);
  }
}
