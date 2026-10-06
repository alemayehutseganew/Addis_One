import { createHash, randomUUID } from 'node:crypto';
import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import {
  AuditActorType,
  FareRuleStatus,
  Prisma,
  StaffRole,
  TransportMode,
  VehicleStatus,
} from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { StaffPrincipal, operatorScope } from '../auth/staff.guard';

export interface CreateStopInput {
  code: string;
  name: string;
  nameAm?: string | null;
  latitude: number;
  longitude: number;
  zone?: string | null;
  hasShelter?: boolean;
}

export interface UpdateStopInput {
  code?: string;
  name?: string;
  nameAm?: string | null;
  latitude?: number;
  longitude?: number;
  zone?: string | null;
  hasShelter?: boolean;
}

export interface CreateVehicleInput {
  plateNumber: string;
  operatorId: string;
  mode: string;
  make?: string | null;
  model?: string | null;
  capacity?: number | null;
}

export interface UpdateVehicleInput {
  plateNumber?: string;
  operatorId?: string;
  mode?: string;
  make?: string | null;
  model?: string | null;
  capacity?: number | null;
  status?: string;
}

export interface CreateRouteInput {
  code: string;
  name: string;
  nameAm?: string | null;
  mode: string;
  operatorId: string;
  distanceMeters?: number;
}

export interface UpdateRouteInput {
  code?: string;
  name?: string;
  nameAm?: string | null;
  mode?: string;
  operatorId?: string;
  distanceMeters?: number;
  isActive?: boolean;
}

export interface ReviseFareRuleInput {
  ruleKey: string;
  mode: string;
  baseFareFils: number;
  perKmFils?: number;
  minimumFareFils?: number;
  originZone?: string | null;
  destinationZone?: string | null;
  routeId?: string | null;
  operatorId?: string | null;
  effectiveFrom?: string;
  changeReason: string;
}

export interface UpdateStaffInput {
  role?: string;
  operatorId?: string | null;
  isActive?: boolean;
}
/**
 * Write-side administration for network reference data.
 *
 * Three rules shape everything here, and each one exists because the schema
 * already commits to it elsewhere:
 *
 *  1. **No hard deletes.** Routes, vehicles, stops and fare rules are all
 *     referenced by trips, tickets and fare calculations that must stay
 *     readable for audit years later. A DELETE here would either violate a
 *     foreign key or, worse, cascade away history. Records are deactivated
 *     instead, which is reversible and leaves the ledger intact.
 *
 *  2. **Fare rules are never edited.** I3 says an issued ticket must point at
 *     the exact numbers it was priced with. Editing a FareRule row in place
 *     would break that the first time a fare changed, so `reviseFareRule`
 *     writes a new version and supersedes the old one.
 *
 *  3. **Every write is audited.** I5 makes AuditEvent append-only, and an
 *     administrator changing a fare or a role is exactly the kind of action an
 *     auditor will ask about later.
 */
@Injectable()
export class AdminService {
  constructor(private readonly prisma: PrismaService) {}

  // ── Stops ────────────────────────────────────────────────────────────────

  /**
   * Stops are city-wide, so there is no operator scoping here. The inactive
   * filter is opt-in so the default view matches what passengers can board.
   */
  async listStops(_staff: StaffPrincipal, includeInactive: boolean) {
    const stops = await this.prisma.stop.findMany({
      where: includeInactive ? {} : { isActive: true },
      orderBy: { name: 'asc' },
      take: 500,
    });

    return stops.map((s) => ({
      id: s.id,
      code: s.code,
      name: s.name,
      nameAm: s.nameAm,
      latitude: Number(s.latitude),
      longitude: Number(s.longitude),
      zone: s.zone,
      isActive: s.isActive,
      hasShelter: s.hasShelter,
    }));
  }

  async createStop(staff: StaffPrincipal, input: CreateStopInput) {
    const data = this.validateStop(input, false);
    const stop = await this.prisma.stop.create({ data: data as Prisma.StopUncheckedCreateInput });
    await this.audit(staff, 'CREATE', 'Stop', stop.id,
      `stop:${stop.code} name=${stop.name}`);
    return stop;
  }

  /**
   * Field-by-field rather than a wholesale replace, so a caller sending a blank
   * optional field cannot silently erase an existing Amharic name it never meant
   * to touch.
   */
  async updateStop(staff: StaffPrincipal, id: string, input: UpdateStopInput) {
    await this.requireStop(id);
    const data = this.validateStop(input, true);

    const stop = await this.prisma.stop.update({ where: { id }, data: data as Prisma.StopUncheckedUpdateInput });
    await this.audit(staff, 'UPDATE', 'Stop', id,
      `stop:${stop.code} name=${stop.name} active=${stop.isActive}`);
    return stop;
  }

  /**
   * Deactivation, not deletion. A stop that served a completed trip stays
   * readable forever; it simply stops being offered to new journeys.
   */
  async setStopActive(staff: StaffPrincipal, id: string, isActive: boolean) {
    await this.requireStop(id);
    const stop = await this.prisma.stop.update({ where: { id }, data: { isActive } });
    await this.audit(staff, 'UPDATE', 'Stop', id,
      `stop:${stop.code} isActive=${isActive}`);
    return stop;
  }

  private async requireStop(id: string) {
    const stop = await this.prisma.stop.findUnique({ where: { id } });
    if (!stop) throw new NotFoundException('Stop not found');
    return stop;
  }
// ── Vehicles ──────────────────────────────────────────────────────────────

  /** Scoped: an operator admin only ever sees their own fleet. */
  async listVehicles(staff: StaffPrincipal, includeInactive: boolean) {
    const scope = operatorScope(staff);

    const vehicles = await this.prisma.vehicle.findMany({
      where: {
        ...(scope ? { operatorId: scope } : {}),
        ...(includeInactive ? {} : { status: { not: VehicleStatus.RETIRED } }),
      },
      include: { operator: { select: { code: true, name: true } } },
      orderBy: { code: 'asc' },
      take: 500,
    });

    return vehicles.map((v) => ({
      id: v.id,
      code: v.code,
      operatorId: v.operatorId,
      operatorCode: v.operator.code,
      mode: v.mode,
      make: v.make,
      model: v.model,
      capacity: v.capacity,
      status: v.status,
    }));
  }

  async createVehicle(staff: StaffPrincipal, input: CreateVehicleInput) {
    const data = await this.validateVehicle(input, false);
    const vehicle = await this.prisma.vehicle.create({ data: data as Prisma.VehicleUncheckedCreateInput });
    await this.audit(staff, 'CREATE', 'Vehicle', vehicle.id,
      `vehicle:${vehicle.code} mode=${vehicle.mode}`);
    return vehicle;
  }

  async updateVehicle(staff: StaffPrincipal, id: string, input: UpdateVehicleInput) {
    await this.requireScopedVehicle(staff, id);
    const data = await this.validateVehicle(input, true);
    const vehicle = await this.prisma.vehicle.update({ where: { id }, data: data as Prisma.VehicleUncheckedUpdateInput });
    await this.audit(staff, 'UPDATE', 'Vehicle', id,
      `vehicle:${vehicle.code} status=${vehicle.status}`);
    return vehicle;
  }

  private async requireScopedVehicle(staff: StaffPrincipal, id: string) {
    const vehicle = await this.prisma.vehicle.findUnique({ where: { id } });
    if (!vehicle) throw new NotFoundException('Vehicle not found');
    this.assertOperator(staff, vehicle.operatorId, 'vehicle');
    return vehicle;
  }

  /**
   * Confirms the caller may act on this operator's data.
   *
   * Centralised on purpose: operator scoping that each endpoint re-implements is
   * operator scoping that one endpoint will eventually get wrong, and the failure
   * mode is an operator admin editing another operator's fleet.
   */
  private assertOperator(staff: StaffPrincipal, operatorId: string, what: string) {
    const scope = operatorScope(staff);
    if (scope && scope !== operatorId) {
      // 404 rather than 403: a 403 would confirm the record exists, turning this
      // screen into an oracle for probing other operators' fleet numbers.
      throw new NotFoundException(`No such ${what}`);
    }
  }

  private async validateVehicle(
    input: CreateVehicleInput | UpdateVehicleInput,
    partial: boolean,
  ) {
    const data: Record<string, unknown> = {};

    if (input.plateNumber !== undefined) {
      const plate = input.plateNumber.trim();
      if (!plate) throw new BadRequestException('Plate number is required');
      data.plateNumber = plate.toUpperCase();
    }

    if (input.mode !== undefined) {
      data.mode = parseEnum(TransportMode, input.mode, 'mode');
    }

    if (input.operatorId !== undefined) {
      // Operator is an FK; checked here so the caller gets a clear message rather
      // than a raw constraint violation from the database.
      const operator = await this.prisma.operator.findUnique({
        where: { id: input.operatorId },
      });
      if (!operator) throw new BadRequestException('Unknown operator');
      data.operatorId = input.operatorId;
    }

    if (input.capacity !== undefined && input.capacity !== null) {
      if (!Number.isInteger(input.capacity) || input.capacity <= 0) {
        throw new BadRequestException('Capacity must be a positive whole number');
      }
      data.capacity = input.capacity;
    }

    if ((input as UpdateVehicleInput).status !== undefined) {
      data.status = parseEnum(
        VehicleStatus,
        (input as UpdateVehicleInput).status as string,
        'status',
      );
    }

    for (const key of ['make', 'model'] as const) {
      if (input[key] !== undefined) data[key] = blankToNull(input[key]);
    }

    if (!partial) {
      // Required on create only — a PATCH is allowed to move a single field.
      if (!data.plateNumber) throw new BadRequestException('Plate number is required');
      if (!data.mode) throw new BadRequestException('Mode is required');
      if (!data.operatorId) throw new BadRequestException('Operator is required');
    }

    return data;
  }
private validateStop(input: CreateStopInput | UpdateStopInput, partial: boolean) {
    const data: Record<string, unknown> = {};

    if (input.code !== undefined) {
      const code = input.code.trim();
      // Stops are referenced by passenger-facing signage. Normalising the case
      // avoids the 'ST-12' vs 'st-12' duplicate pair that a case-sensitive unique
      // index happily accepts.
      if (!/^[A-Za-z0-9-]{2,32}$/.test(code)) {
        throw new BadRequestException('Stop code must be 2-32 letters, digits or dashes');
      }
      data.code = code.toUpperCase();
    }

    if (input.name !== undefined) {
      const name = input.name.trim();
      if (!name) throw new BadRequestException('Stop name is required');
      data.name = name;
    }

    if (input.latitude !== undefined) {
      if (!Number.isFinite(input.latitude) || input.latitude < -90 || input.latitude > 90) {
        throw new BadRequestException('Latitude must be between -90 and 90');
      }
      data.latitude = input.latitude;
    }

    if (input.longitude !== undefined) {
      if (!Number.isFinite(input.longitude) || input.longitude < -180 || input.longitude > 180) {
        throw new BadRequestException('Longitude must be between -180 and 180');
      }
      data.longitude = input.longitude;
    }

    if (input.zone !== undefined) data.zone = blankToNull(input.zone);
    if (input.nameAm !== undefined) data.nameAm = blankToNull(input.nameAm);
    if (input.hasShelter !== undefined) data.hasShelter = Boolean(input.hasShelter);

    if (!partial) {
      if (!data.code) throw new BadRequestException('Stop code is required');
      if (!data.name) throw new BadRequestException('Stop name is required');
      if (data.latitude === undefined) throw new BadRequestException('Latitude is required');
      if (data.longitude === undefined) throw new BadRequestException('Longitude is required');
    }

    return data;
  }
// ── Routes ────────────────────────────────────────────────────────────────

  /**
   * Routes carry their stops. The stop list is returned inline rather than as a
   * separate call so the admin form can render a route and its sequence in one
   * round trip — an operator editing a route is always looking at both.
   */
  async listRoutes(staff: StaffPrincipal, includeInactive: boolean) {
    const scope = operatorScope(staff);

    const routes = await this.prisma.route.findMany({
      where: {
        ...(scope ? { operatorId: scope } : {}),
        ...(includeInactive ? {} : { isActive: true }),
      },
      include: {
        operator: { select: { code: true, name: true } },
        stops: {
          orderBy: { sequence: 'asc' },
          include: { stop: { select: { id: true, code: true, name: true } } },
        },
      },
      orderBy: { code: 'asc' },
      take: 300,
    });

    return routes.map((r) => ({
      id: r.id,
      code: r.code,
      name: r.name,
      nameAm: r.nameAm,
      mode: r.mode,
      operatorId: r.operatorId,
      operatorCode: r.operator.code,
      isActive: r.isActive,
      distanceMeters: r.distanceMeters,
      stops: r.stops.map((rs) => ({
        stopId: rs.stopId,
        code: rs.stop.code,
        name: rs.stop.name,
        sequence: rs.sequence,
      })),
    }));
  }

  async createRoute(staff: StaffPrincipal, input: CreateRouteInput) {
    const data = await this.validateRoute(input, false);
    const route = await this.prisma.route.create({ data: data as Prisma.RouteUncheckedCreateInput });
    await this.audit(staff, 'CREATE', 'Route', route.id,
      `route:${route.code} name=${route.name} mode=${route.mode}`);
    return route;
  }

  async updateRoute(staff: StaffPrincipal, id: string, input: UpdateRouteInput) {
    const route = await this.prisma.route.findUnique({ where: { id } });
    if (!route) throw new NotFoundException('Route not found');
    this.assertOperator(staff, route.operatorId, 'route');

    const data = await this.validateRoute(input, true);
    const updated = await this.prisma.route.update({ where: { id }, data: data as Prisma.RouteUncheckedUpdateInput });
    await this.audit(staff, 'UPDATE', 'Route', id,
      `route:${updated.code} active=${updated.isActive}`);
    return updated;
  }

  /**
   * Replaces a route's stop sequence.
   *
   * Written as a delete-then-create inside one transaction rather than a diff.
   * The obvious optimisation — matching stops that are unchanged and moving only
   * the differences — would rewrite rows whose ids an audit record already points
   * at, for no measurable gain on a route's worth of rows.
   */
  async setRouteStops(
    staff: StaffPrincipal,
    routeId: string,
    stops: Array<{ stopId: string; sequence: number }>,
  ) {
    const route = await this.prisma.route.findUnique({ where: { id: routeId } });
    if (!route) throw new NotFoundException('Route not found');
    this.assertOperator(staff, route.operatorId, 'route');

    if (!Array.isArray(stops) || stops.length === 0) {
      throw new BadRequestException('A route needs at least one stop');
    }

    // Sequences must be distinct or the (routeId, sequence) unique index rejects
    // the insert with an error the operator cannot act on.
    const seen = new Set<number>();
    for (const s of stops) {
      if (!Number.isInteger(s.sequence) || s.sequence < 0) {
        throw new BadRequestException('Stop sequence must be a non-negative whole number');
      }
      if (seen.has(s.sequence)) {
        throw new BadRequestException('Two stops share sequence ' + s.sequence);
      }
      seen.add(s.sequence);
    }

    const ids = stops.map((s) => s.stopId);
    const known = await this.prisma.stop.count({ where: { id: { in: ids } } });
    if (known !== new Set(ids).size) {
      throw new BadRequestException('One or more stops do not exist');
    }

    await this.prisma.$transaction([
      this.prisma.routeStop.deleteMany({ where: { routeId } }),
      this.prisma.routeStop.createMany({
        data: stops.map((s) => ({ routeId, stopId: s.stopId, sequence: s.sequence })),
      }),
    ]);

    await this.audit(staff, 'UPDATE', 'Route', routeId,
      `route:${route.code} stops=${stops.length}`);

    const refreshed = await this.listRoutes(staff, true);
    return refreshed.find((r) => r.id === routeId) ?? null;
  }
private async validateRoute(
    input: CreateRouteInput | UpdateRouteInput,
    partial: boolean,
  ) {
    const data: Record<string, unknown> = {};

    if (input.code !== undefined) {
      const code = input.code.trim().toUpperCase();
      if (!/^[A-Z0-9-]{2,32}$/.test(code)) {
        throw new BadRequestException('Route code must be 2-32 letters, digits or dashes');
      }
      data.code = code;
    }

    if (input.name !== undefined) {
      const name = input.name.trim();
      if (!name) throw new BadRequestException('Route name is required');
      data.name = name;
    }

    if (input.mode !== undefined) data.mode = parseEnum(TransportMode, input.mode, 'mode');

    if (input.operatorId !== undefined) {
      const operator = await this.prisma.operator.findUnique({
        where: { id: input.operatorId },
      });
      if (!operator) throw new BadRequestException('Unknown operator');
      data.operatorId = input.operatorId;
    }

    if (input.distanceMeters !== undefined) {
      if (input.distanceMeters < 0) {
        throw new BadRequestException('Distance cannot be negative');
      }
      data.distanceMeters = input.distanceMeters;
    }

    if (input.nameAm !== undefined) data.nameAm = blankToNull(input.nameAm);
    if ((input as UpdateRouteInput).isActive !== undefined) {
      data.isActive = Boolean((input as UpdateRouteInput).isActive);
    }

    if (!partial) {
      if (!data.code) throw new BadRequestException('Route code is required');
      if (!data.name) throw new BadRequestException('Route name is required');
      if (!data.mode) throw new BadRequestException('Mode is required');
      if (!data.operatorId) throw new BadRequestException('Operator is required');
    }

    return data;
  }

  // ── Fare rules (I3) ─────────────────────────────────────────────────────

  async listFareRules(staff: StaffPrincipal, ruleKey?: string) {
    const scope = operatorScope(staff);

    const rules = await this.prisma.fareRule.findMany({
      where: {
        ...(ruleKey ? { ruleKey } : {}),
        // A null operatorId means a city-wide rule. An operator-scoped caller
        // sees city-wide rules plus their own, never another operator's.
        ...(scope ? { OR: [{ operatorId: null }, { operatorId: scope }] } : {}),
      },
      orderBy: [{ ruleKey: 'asc' }, { version: 'desc' }],
      take: 300,
    });

    return rules.map((r) => ({
      id: r.id,
      ruleKey: r.ruleKey,
      version: r.version,
      mode: r.mode,
      originZone: r.originZone,
      destinationZone: r.destinationZone,
      baseFareFils: r.baseFareFils,
      perKmFils: r.perKmFils,
      minimumFareFils: r.minimumFareFils,
      status: r.status,
      effectiveFrom: r.effectiveFrom,
      effectiveUntil: r.effectiveUntil,
      changeReason: r.changeReason,
    }));
  }
// ── Operators ────────────────────────────────────────────────────────────

  /**
   * Names and codes only. Licence numbers and settlement accounts are commercial
   * data that a dropdown has no business carrying around, so they are not
   * selected even though they exist on the row.
   */
  async listOperators() {
    return this.prisma.operator.findMany({
      select: { id: true, code: true, name: true, status: true },
      orderBy: { code: 'asc' },
      take: 200,
    });
  }

  // ── Fare rules (I3) — continued ─────────────────────────────────────────

  /**
   * Creates the next version of a fare rule. There is no "update" endpoint, and
   * that absence is the feature.
   *
   * A ticket already issued holds a `fareRuleVersionId` pointing at the exact row
   * it was priced with. If that row could be edited, a later price change would
   * retroactively alter what a citizen was charged and the fare history would
   * stop explaining itself. So a revision writes a new row at `version + 1`,
   * leaves the old one untouched, and closes the old version's effective window.
   *
   * The supersede and the insert run in one transaction: a rule superseded
   * without its successor existing would leave the network with no active fare.
   */
  async reviseFareRule(staff: StaffPrincipal, input: ReviseFareRuleInput) {
    const reason = (input.changeReason ?? '').trim();
    // A fare change with no stated reason cannot be defended to an auditor, so
    // the reason is mandatory rather than optional metadata.
    if (reason.length < 3) {
      throw new BadRequestException('A change reason of at least 3 characters is required');
    }

    const ruleKey = (input.ruleKey ?? '').trim();
    if (!ruleKey) throw new BadRequestException('Rule key is required');

    const baseFareFils = Math.round(Number(input.baseFareFils));
    if (!Number.isFinite(baseFareFils) || baseFareFils < 0) {
      throw new BadRequestException('Base fare must be zero or more fils');
    }

    const previous = await this.prisma.fareRule.findFirst({
      where: { ruleKey },
      orderBy: { version: 'desc' },
    });

    const version = (previous?.version ?? 0) + 1;
    const effectiveFrom = input.effectiveFrom ? new Date(input.effectiveFrom) : new Date();
    if (Number.isNaN(effectiveFrom.getTime())) {
      throw new BadRequestException('Effective-from is not a valid date');
    }

    const created = await this.prisma.$transaction(async (tx) => {
      if (previous) {
        await tx.fareRule.update({
          where: { id: previous.id },
          data: {
            status: FareRuleStatus.SUPERSEDED,
            // Closing the window at the successor's start date means the two
            // versions never overlap, so a lookup cannot find both.
            effectiveUntil: effectiveFrom,
          },
        });
      }

      return tx.fareRule.create({
        data: {
          ruleKey,
          version,
          mode: parseEnum(TransportMode, input.mode, 'mode'),
          baseFareFils,
          perKmFils: Math.max(0, Math.round(Number(input.perKmFils ?? 0))),
          minimumFareFils: Math.max(0, Math.round(Number(input.minimumFareFils ?? 0))),
          originZone: blankToNull(input.originZone),
          destinationZone: blankToNull(input.destinationZone),
          routeId: input.routeId || null,
          operatorId: input.operatorId || null,
          effectiveFrom,
          // Draft, never ACTIVE on creation. Dual control means a second,
          // differently-privileged person activates it; an administrator who can
          // both raise and approve a fare is not dual control at all.
          status: FareRuleStatus.DRAFT,
          createdByStaffId: staff.id,
          changeReason: reason,
        },
      });
    });

    await this.audit(staff, 'CREATE', 'FareRule', created.id,
      `fare:${created.ruleKey} v${created.version} base=${created.baseFareFils}fils`);
    return created;
  }

  /**
   * Activates a drafted fare version.
   *
   * Restricted to finance/bureau roles at the controller, and deliberately not
   * allowed for the draft's own author: the same person must not both raise a
   * fare and sign it off.
   */
  async activateFareRule(staff: StaffPrincipal, id: string) {
    const rule = await this.prisma.fareRule.findUnique({ where: { id } });
    if (!rule) throw new NotFoundException('Fare rule not found');

    if (rule.status !== FareRuleStatus.DRAFT) {
      throw new ConflictException(`Only a draft can be activated (this one is ${rule.status})`);
    }

    if (rule.createdByStaffId === staff.id) {
      throw new ForbiddenException('A fare rule must be approved by someone other than its author');
    }

    // Only one ACTIVE version per ruleKey. Superseding the rest here rather than
    // trusting the caller's ordering keeps the invariant true even if two admins
    // activate two drafts at the same moment.
    const superseded = await this.prisma.fareRule.findMany({
      where: { ruleKey: rule.ruleKey, status: FareRuleStatus.ACTIVE, id: { not: id } },
      select: { id: true },
    });

    const activated = await this.prisma.$transaction(async (tx) => {
      for (const old of superseded) {
        await tx.fareRule.update({
          where: { id: old.id },
          data: { status: FareRuleStatus.SUPERSEDED, effectiveUntil: new Date() },
        });
      }
      return tx.fareRule.update({
        where: { id },
        data: {
          status: FareRuleStatus.ACTIVE,
          approvedByStaffId: staff.id,
          approvedAt: new Date(),
        },
      });
    });

    await this.audit(staff, 'APPROVE', 'FareRule', id,
      `fare:${activated.ruleKey} v${activated.version} base=${activated.baseFareFils}fils`);
    return activated;
  }
// ── Staff ────────────────────────────────────────────────────────────────

  /**
   * Staff are listed with their operator so an administrator can see who belongs
   * where. Contact details are deliberately excluded: this screen is for managing
   * access, and a staff phone number is not needed to do that.
   */
  async listStaff(_staff: StaffPrincipal, includeInactive: boolean) {
    const people = await this.prisma.staff.findMany({
      where: includeInactive ? {} : { isActive: true },
      include: {
        user: { select: { displayName: true } },
        operator: { select: { code: true, name: true } },
      },
      orderBy: { role: 'asc' },
      take: 500,
    });

    return people.map((p) => ({
      id: p.id,
      displayName: p.user.displayName,
      role: p.role,
      employeeCode: p.employeeCode,
      badgeNumber: p.badgeNumber,
      operatorId: p.operatorId,
      operatorCode: p.operator?.code ?? null,
      isActive: p.isActive,
      terminatedAt: p.terminatedAt,
    }));
  }

  /**
   * Changes a staff member's role, operator or active status.
   *
   * The most dangerous endpoint in the module — it is how someone becomes an
   * administrator — so it carries three guards:
   *
   *  - the caller cannot change their own role, which stops both accidental
   *    self-lockout and a staged escalation where an admin quietly promotes
   *    themselves and nobody notices in the diff;
   *  - SUPER_ADMIN cannot be granted by anyone who is not already SUPER_ADMIN,
   *    so a TRANSPORT_BUREAU_ADMIN cannot mint a peer;
   *  - demotion records a termination date rather than flipping isActive, so the
   *    trail shows when access actually ended.
   */
  async updateStaff(staff: StaffPrincipal, id: string, input: UpdateStaffInput) {
    const target = await this.prisma.staff.findUnique({ where: { id } });
    if (!target) throw new NotFoundException('Staff member not found');

    if (target.id === staff.id && input.role !== undefined && input.role !== staff.role) {
      throw new ForbiddenException('You cannot change your own role');
    }

    const data: Record<string, unknown> = {};

    if (input.role !== undefined) {
      const role = parseEnum(StaffRole, input.role, 'role');
      if (role === StaffRole.SUPER_ADMIN && staff.role !== StaffRole.SUPER_ADMIN) {
        throw new ForbiddenException('Only a super admin can grant super admin');
      }
      if (target.role === StaffRole.SUPER_ADMIN && role !== StaffRole.SUPER_ADMIN) {
        throw new ForbiddenException('Demoting a super admin requires a super admin');
      }
      data.role = role;
    }

    if (input.operatorId !== undefined) {
      if (input.operatorId === null) {
        // City-wide roles legitimately have no operator; anyone else without one
        // would be unscoped and therefore see nothing at all.
        const role = (data.role as StaffRole | undefined) ?? target.role;
        if (!CITY_WIDE_STAFF_ROLES.includes(role)) {
          throw new BadRequestException(`${role} staff must belong to an operator`);
        }
        data.operatorId = null;
      } else {
        const operator = await this.prisma.operator.findUnique({
          where: { id: input.operatorId },
        });
        if (!operator) throw new BadRequestException('Unknown operator');
        data.operatorId = input.operatorId;
      }
    }

    if (input.isActive !== undefined) {
      const isActive = Boolean(input.isActive);
      data.isActive = isActive;
      // Terminated rather than merely deactivated, so the record says when access
      // ended. Reinstating clears it again.
      data.terminatedAt = isActive ? null : new Date();
    }

    if (Object.keys(data).length === 0) {
      throw new BadRequestException('Nothing to change');
    }

    const updated = await this.prisma.staff.update({ where: { id }, data: data as Prisma.StaffUncheckedUpdateInput });
    await this.audit(staff, 'UPDATE', 'Staff', id,
      `staff:${updated.employeeCode ?? updated.id} role=${updated.role} active=${updated.isActive}`);
    return updated;
  }
// ── Audit ──────────────────────────────────────────────────────────────

  /**
   * Appends an AuditEvent.
   *
   * A failure to write the audit record must not silently succeed the business
   * change — an unlogged privilege escalation is worse than a failed request —
   * so this is awaited and its errors propagate to the caller.
   *
   * Only a short summary string is stored, never previous values of sensitive
   * fields: AuditEvent is readable by auditors and should not become a
   * convenient second home for personal data.
   */
  private async audit(
    staff: StaffPrincipal,
    action: string,
    resourceType: string,
    resourceId: string,
    summary: string,
  ) {
    // The previous event's hash is folded in so the log is a chain: removing or
    // editing a row in the middle breaks every hash after it, which is what makes
    // bulk tampering detectable after the fact rather than merely discouraged.
    const previous = await this.prisma.auditEvent.findFirst({
      orderBy: { id: 'desc' },
      select: { eventHash: true },
    });

    const eventId = randomUUID();
    const timestamp = new Date().toISOString();
    const eventHash = createHash('sha256')
      .update(previous?.eventHash ?? '')
      .update(
        JSON.stringify({ eventId, action, resourceType, resourceId, summary, actorId: staff.id, timestamp }),
      )
      .digest('hex');

    await this.prisma.auditEvent.create({
      data: {
        eventId,
        actorId: staff.id,
        actorType: AuditActorType.STAFF,
        actorRole: staff.role,
        action,
        resourceType,
        resourceId,
        reason: summary,
        timestamp: new Date(timestamp),
        ipAddress: staff.ipAddress,
        userAgent: staff.userAgent,
        previousHash: previous?.eventHash ?? null,
        eventHash,
      },
    });
  }
}

/** Roles that may exist without an operator, because they see the whole city. */
const CITY_WIDE_STAFF_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
  StaffRole.AUDITOR,
];

/**
 * Parses a string into an enum member, rejecting unknown values.
 *
 * A raw cast would let `mode: "HELICOPTER"` through to Prisma and surface as an
 * opaque database error, so the failure is reported against the field instead.
 */
function parseEnum<T extends Record<string, string>>(
  enumObject: T,
  value: string,
  field: string,
): T[keyof T] {
  if (!Object.values(enumObject).includes(value)) {
    throw new BadRequestException(
      `${field} must be one of: ${Object.values(enumObject).join(', ')}`,
    );
  }
  return value as T[keyof T];
}

/** Treats an empty or whitespace-only string as "no value", not as empty text. */
function blankToNull(value: string | null | undefined): string | null {
  if (value === undefined || value === null) return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}
