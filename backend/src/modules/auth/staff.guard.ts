import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  SetMetadata,
  UnauthorizedException,
  createParamDecorator,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { StaffRole } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';

export const STAFF_ROLES_KEY = 'addis:staff-roles';

/**
 * Restricts a route to the listed staff roles.
 *
 * Roles are NOT baked into the JWT. A token stays valid for its whole lifetime,
 * so a promotion or a termination recorded in the database would not take effect
 * until the holder happened to sign in again. The role is therefore always read
 * live, on every request.
 */
export const Roles = (...roles: StaffRole[]) => SetMetadata(STAFF_ROLES_KEY, roles);

export interface StaffPrincipal {
  id: string;
  userId: string;
  role: StaffRole;
  operatorId: string | null;
  employeeCode: string | null;
  displayName: string | null;
  phone: string;
  /**
   * Caller's network address and user agent.
   *
   * Captured here because privileged actions are audited, and "who changed this
   * fare" is only half an answer without "from where". Read from the live request
   * rather than the token, so a session that moved between networks is recorded
   * where it actually happened.
   */
  ipAddress: string;
  userAgent: string;
}

/**
 * Roles that see the whole city rather than a single operator.
 *
 * This is the boundary the schema already draws: "staff may only act on their
 * own operator's resources unless they hold a bureau or finance role". An
 * OPERATOR_ADMIN who can page the whole network's revenue would make that
 * sentence false, so operator scoping is enforced here rather than left to each
 * query to remember.
 */
const CITY_WIDE_ROLES: readonly StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
  StaffRole.AUDITOR,
];

/** True when this role may see data for every operator. */
export function isCityWide(role: StaffRole): boolean {
  return CITY_WIDE_ROLES.includes(role);
}

/**
 * The operator a staff member is confined to, or null when they see the city.
 *
 * A bureau/finance/auditor role with an operatorId attached still sees
 * everything: the role is the grant, the operator is just where they happen to
 * be posted. Narrowing them would be a quiet downgrade nobody asked for.
 */
export function operatorScope(staff: StaffPrincipal): string | null {
  return isCityWide(staff.role) ? null : staff.operatorId;
}

/**
 * Staff authorization.
 *
 * Runs after JwtAuthGuard, which has already put the caller on `request.user`.
 * Being signed in is not enough: a passenger account holds a perfectly valid
 * citizen token, and without this guard any of them could read the revenue of
 * the entire transport system.
 *
 * Rejection is deliberately uniform. Telling a signed-in non-staff that "you
 * exist but are not staff" confirms the account is real; a flat 403 leaks
 * nothing and is equally actionable for a legitimate operator whose staff record
 * was not provisioned.
 */
@Injectable()
export class StaffGuard implements CanActivate {
  constructor(
    private readonly prisma: PrismaService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const user = request.user;

    if (!user?.id) {
      // JwtAuthGuard should have rejected this already. Guarding anyway so that
      // a future route mounted with only this guard cannot fall open.
      throw new UnauthorizedException('Authentication required');
    }

    const staff = await this.prisma.staff.findUnique({
      where: { userId: user.id },
      select: {
        id: true,
        userId: true,
        role: true,
        operatorId: true,
        employeeCode: true,
        isActive: true,
        terminatedAt: true,
        user: { select: { displayName: true, phone: true } },
      },
    });

    if (!staff || !staff.isActive || staff.terminatedAt !== null) {
      throw new ForbiddenException('Staff access required');
    }

    request.staff = {
      id: staff.id,
      userId: staff.userId,
      role: staff.role,
      operatorId: staff.operatorId,
      employeeCode: staff.employeeCode,
      displayName: staff.user.displayName,
      phone: staff.user.phone,
      // request.ip honours the trust proxy when one is configured, so this is
      // the client address rather than the load balancer's.
      ipAddress: request.ip ?? '',
      userAgent: String(request.headers['user-agent'] ?? ''),
    } satisfies StaffPrincipal;

    const required = this.reflector.getAllAndOverride<StaffRole[]>(
      STAFF_ROLES_KEY,
      [context.getHandler(), context.getClass()],
    );

    if (required && required.length > 0 && !required.includes(staff.role)) {
      throw new ForbiddenException('Insufficient role for this resource');
    }

    return true;
  }
}

/** Injects the authenticated staff member into a handler parameter. */
export const CurrentStaff = createParamDecorator(
  (_data: unknown, context: ExecutionContext): StaffPrincipal => {
    return context.switchToHttp().getRequest().staff;
  },
);
