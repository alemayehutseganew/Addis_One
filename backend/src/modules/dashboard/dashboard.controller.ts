import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { StaffRole } from '@prisma/client';
import {
  CurrentStaff,
  Roles,
  StaffGuard,
  StaffPrincipal,
  isCityWide,
} from '../auth/staff.guard';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { DatabaseInspectorService } from './database-inspector.service';
import { DashboardService } from './dashboard.service';
import {
  ADMIN_ROLES,
  DASHBOARD_ROLES,
  DATABASE_ROLES,
  FINANCE_ROLES,
} from '../auth/policy';
import {
  resolveDateRange,
  resolvePage,
  resolvePageSize,
} from './dashboard-query';

/**
 * Read-only reporting endpoints.
 *
 * Every route is behind JwtAuthGuard AND StaffGuard, in that order: the first
 * establishes who is calling, the second establishes that they are staff and
 * which role they hold. A citizen token is valid for the API but must not reach
 * revenue, so the second guard is not optional on any route here.
 *
 * There are no POST/PUT/DELETE handlers. This is a reporting surface over
 * records that are already immutable or governed elsewhere — a dashboard that
 * could approve a fare or void a ticket would need dual-control audit on every
 * action, and that belongs in a proper admin module rather than being bolted on
 * to a read-only screen.
 */
@Controller('dashboard')
@UseGuards(JwtAuthGuard, StaffGuard)
@Roles(...DASHBOARD_ROLES)
export class DashboardController {
  constructor(
    private readonly dashboard: DashboardService,
    private readonly database: DatabaseInspectorService,
  ) {}

  /**
   * Who the signed-in staff member is and what they may see.
   *
   * The client uses this to decide which panels to render, so that a
   * supervisor is never shown a finance tab that would only 403. The server
   * still enforces every rule — this is presentation, not security.
   */
  @Get('session')
  session(@CurrentStaff() staff: StaffPrincipal) {
    return {
      staff: {
        displayName: staff.displayName,
        employeeCode: staff.employeeCode,
        role: staff.role,
        operatorId: staff.operatorId,
        // Sent back so the client can render an "Addis One Operations" heading
        // naming the person, which matters on a screen left open on a desk.
        display: staff.displayName ?? staff.employeeCode ?? staff.phone,
      },
      permissions: {
        cityWide: isCityWide(staff.role),
        canViewFinance: FINANCE_ROLES.includes(staff.role),
        canViewFares: FINANCE_ROLES.includes(staff.role),
        // Database internals are narrower still — see DATABASE_ROLES in
        // dashboard.controller.ts for why an auditor does not get this one.
        canViewDatabase: DATABASE_ROLES.includes(staff.role),
        // Write-side permissions, mirroring ADMIN_ROLES and the narrower role
        // lists on the staff routes. The client hides what the server refuses.
        canManage: ADMIN_ROLES.includes(staff.role),
        canManageStaff: (
          [StaffRole.SUPER_ADMIN, StaffRole.TRANSPORT_BUREAU_ADMIN] as StaffRole[]
        ).includes(staff.role),
      },
    };
  }

  @Get('overview')
  overview(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    return this.dashboard.overview(staff, resolveDateRange(from, to));
  }

  @Get('revenue')
  @Roles(...FINANCE_ROLES)
  revenue(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
    @Query('status') status?: string,
  ) {
    return this.dashboard.revenue(
      staff,
      resolveDateRange(from, to),
      resolvePage(page),
      resolvePageSize(pageSize),
      status,
    );
  }

  @Get('operations')
  operations(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    return this.dashboard.operations(staff, resolveDateRange(from, to));
  }

  @Get('network')
  network(@CurrentStaff() staff: StaffPrincipal) {
    return this.dashboard.network(staff);
  }

  @Get('fares')
  @Roles(...FINANCE_ROLES)
  fares(@CurrentStaff() staff: StaffPrincipal) {
    return this.dashboard.fares(staff);
  }

  @Get('passengers')
  passengers(
    @CurrentStaff() staff: StaffPrincipal,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    return this.dashboard.passengers(resolveDateRange(from, to));
  }

  /**
   * Database size, object counts, connection pool, table bloat and index usage.
   *
   * Read-only catalog reporting, and read-only at the database level too: the
   * inspector issues SELECTs against pg_stat_* views and no application table.
   */
  @Get('database')
  @Roles(...DATABASE_ROLES)
  databaseStats(@CurrentStaff() staff: StaffPrincipal) {
    return this.database.inspect(staff);
  }
}
