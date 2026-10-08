import {
  Body,
  Controller,
  Get,
  HttpCode,
  Injectable,
  Logger,
  NotFoundException,
  Post,
  UseGuards,
} from '@nestjs/common';
import { IsString, Matches, MinLength } from 'class-validator';
import { CurrentUser, JwtAuthGuard, AuthenticatedUser } from './jwt-auth.guard';
import {
  CurrentStaff,
  StaffGuard,
  StaffPrincipal,
  isCityWide,
} from './staff.guard';
import { ADMIN_ROLES, SCAN_ROLES, capabilitiesFor } from './policy';
import { DevLoginGuard } from './dev-login.guard';
import { OtpService } from './otp.service';
import { TestLoginGuard } from './test-login.guard';
import { TestLoginService } from './test-login.service';
import { TokenService } from './token.service';
import { PrismaService } from '../../prisma/prisma.service';
import { UserStatus } from '@prisma/client';

class RequestOtpDto {
  @IsString()
  @Matches(/^\+251[79]\d{8}$/, {
    message: 'phone must be a canonical Ethiopian mobile, e.g. +251911234567',
  })
  phone!: string;
}

class VerifyOtpDto {
  @IsString()
  @Matches(/^\+251[79]\d{8}$/)
  phone!: string;

  @IsString()
  @MinLength(6)
  @Matches(/^\d{6}$/, { message: 'code must be six digits' })
  code!: string;
}

class RefreshDto {
  @IsString()
  @MinLength(20)
  refreshToken!: string;
}

class PasswordLoginDto {
  @IsString()
  @MinLength(3)
  username!: string;

  @IsString()
  @MinLength(4)
  password!: string;
}

/**
 * Development-only sign-in that skips the OTP step.
 *
 * Enabled only when `DEV_STAFF_LOGIN=true` AND `NODE_ENV` is not `production`.
 * Both conditions are required: the flag alone would open this on a deployed
 * environment that merely inherited the .env, and the NODE_ENV check alone would
 * open it on a production build pointed at a dev database.
 *
 * What this does NOT do, deliberately:
 *
 *  - It never creates a Staff row. A number with no active staff record is given
 *    a plain citizen account, never an employee one. This is the invariant that
 *    matters: the bypass is a shortcut past the SMS round trip, and it cannot
 *    mint authority, because authority is exactly what a Staff row confers. A
 *    terminated or deactivated employee who calls this gets a citizen session,
 *    not their old role back.
 *  - It does not weaken anything downstream. The token is signed by the same
 *    TokenService with the same secret and TTL as an OTP login, and JwtAuthGuard
 *    and StaffGuard still run on every subsequent request. Roles, operator scoping
 *    and the audit chain are all unchanged.
 *
 * When it is off, `registerDevRoutes` is never called, so the route does not exist
 * and answers 404. Hiding a control in the UI while leaving a live endpoint behind
 * would be worse than having neither.
 */
@Injectable()
export class DevLoginService {
  private readonly logger = new Logger('DevLogin');

  constructor(
    private readonly prisma: PrismaService,
    private readonly tokens: TokenService,
  ) {}

  /**
   * Issues a session for a phone, with or without an OTP.
   *
   * Whether this may be called at all is decided by DevLoginGuard before the
   * request reaches here, so this method does not re-check the flag. It assumes
   * the route is armed and enforces only the per-account condition.
   *
   * A number that already holds an active staff record gets that identity, which
   * is how the staff handheld signs in. Any other number is given a plain citizen
   * account — created on first use — which is how the passenger app signs in
   * without an SMS round trip. Neither path can produce a Staff row, so this can
   * never grant authority it was not already given.
   */
  async signIn(phone: string) {
    const staff = await this.prisma.staff.findFirst({
      where: { user: { phone }, isActive: true, terminatedAt: null },
      select: { userId: true },
    });

    // The citizen branch deliberately does not create a Staff row, and does not
    // touch `phoneVerifiedAt` either: a bypass that marks a number as
    // phone-verified would quietly make later OTP-based sign-ins trust a
    // verification that never happened.
    const user = staff
      ? null
      : await this.prisma.user.upsert({
          where: { phone },
          create: { phone, displayName: null },
          // `update: {}` on purpose. Reactivating or renaming an existing account
          // here would let a bypass undo a suspension the product applied on
          // purpose; JwtAuthGuard still refuses SUSPENDED and CLOSED accounts
          // afterwards, and this does not interfere with that.
          update: {},
          select: { id: true, displayName: true },
        });

    const userId = staff?.userId ?? user!.id;

    // Loud on every use. A bypass that is easy to forget about is the kind that
    // reaches production, and this line is how it would be noticed.
    this.logger.warn(
      `[DEV LOGIN] issued a session for ${phone} without OTP verification ` +
        `${staff ? 'as STAFF' : 'as a CITIZEN'} — ` +
        'DEV_STAFF_LOGIN is enabled; do not use this build in production.',
    );

    const pair = await this.tokens.issueFor(userId, phone);
    return {
      ok: true,
      accessToken: pair.accessToken,
      refreshToken: pair.refreshToken,
      expiresIn: pair.expiresIn,
      displayName: user?.displayName ?? null,
    } as const;
  }
}

@Controller('auth')
export class AuthController {
  constructor(
    private readonly otp: OtpService,
    private readonly tokens: TokenService,
    private readonly prisma: PrismaService,
    private readonly dev: DevLoginService,
    private readonly testLogin: TestLoginService,
  ) {}

  /**
   * Always returns 202, whether or not the number exists.
   *
   * A different response for an unknown number would turn this endpoint into an
   * oracle for enumerating who has an account.
   */
  @Post('request-otp')
  @HttpCode(202)
  async requestOtp(@Body() dto: RequestOtpDto): Promise<{ sent: true }> {
    await this.otp.issue(dto.phone);
    return { sent: true };
  }

  @Post('verify-otp')
  @HttpCode(200)
  async verifyOtp(@Body() dto: VerifyOtpDto) {
    const ok = await this.otp.verify(dto.phone, dto.code);

    // Deliberately vague: "invalid" covers a wrong code, an expired one, and
    // an exhausted allowance, so the client cannot probe which.
    if (!ok) {
      return { ok: false, error: 'invalid_or_expired' } as const;
    }

    const user = await this.findOrCreateUser(dto.phone);
    const pair = await this.tokens.issueFor(user.id, user.phone);

    return {
      ok: true,
      accessToken: pair.accessToken,
      refreshToken: pair.refreshToken,
      expiresIn: pair.expiresIn,
      displayName: user.displayName,
    } as const;
  }

  @Post('refresh')
  @HttpCode(200)
  async refresh(@Body() dto: RefreshDto) {
    return this.tokens.rotate(dto.refreshToken);
  }

  @Get('me')
  @UseGuards(JwtAuthGuard)
  async me(@CurrentUser() user: AuthenticatedUser) {
    return user;
  }

  @Post('logout')
  @HttpCode(204)
  @UseGuards(JwtAuthGuard)
  async logout(@CurrentUser() user: AuthenticatedUser): Promise<void> {
    await this.tokens.revokeAllFor(user.id);
  }

  /**
   * Who the signed-in staff member is, for the inspector's handheld.
   *
   * Separate from `GET /dashboard/session` on purpose. That route sits behind
   * DASHBOARD_ROLES, which deliberately excludes every field role — an inspector
   * has no business reading network revenue, and that exclusion is the whole
   * point of the list. But it means the handheld could never ask "who am I" at
   * all: the staff app pointed at the dashboard route, so every INSPECTOR,
   * CONDUCTOR, TICKET_OFFICER and AGENT was refused a 403 at sign-in and reached
   * the scanner with no role, where the app could only say "you are signed in
   * as " with nothing after it.
   *
   * Two audiences, so two endpoints. This one is reachable by any active staff
   * member because naming yourself is not privileged information — it reveals
   * only the caller's own identity and role, and it reports nothing they could
   * not already see. The dashboard's version stays restricted because it also
   * reports what they may see, which genuinely is privileged.
   *
   * `canValidate` is answered from SCAN_ROLES rather than left for the client to
   * work out, so the handheld and the scan route cannot disagree about which
   * roles may scan.
   */
  @Get('staff-session')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, StaffGuard)
  staffSession(@CurrentStaff() staff: StaffPrincipal) {
    return {
      staff: {
        displayName: staff.displayName,
        employeeCode: staff.employeeCode,
        role: staff.role,
        operatorId: staff.operatorId,
        // Same fallback as the dashboard's, so a handset left face-up on a desk
        // still names a person when the staff row carries no display name.
        display: staff.displayName ?? staff.employeeCode ?? staff.phone,
      },
      permissions: {
        canValidate: SCAN_ROLES.includes(staff.role),
        canManage: ADMIN_ROLES.includes(staff.role),
        // Reported, not enforced here — it tells the app how to explain a
        // narrow history, and the scan route still scopes every read itself.
        cityWide: isCityWide(staff.role),
      },
      // The full answer, so the handheld can offer a driver a trip screen and a
      // finance officer a revenue report without shipping a second copy of these
      // role lists in Dart. `permissions` above is kept for compatibility with
      // the existing client; it is the same information, narrower.
      //
      // Reporting a capability does not grant it: every route re-checks its own
      // `@Roles` list, so a client that ignores this and offers everything gains
      // nothing but a 403.
      capabilities: capabilitiesFor(staff.role),
    };
  }

  /**
   * Reports whether the development shortcut is armed.
   *
   * The page has to learn this from the server rather than from a build-time
   * switch, because the page is a static file with no access to server
   * configuration. Probing the sign-in route itself would not work: it answers 404
   * both when the route is unregistered *and* when the route is live but the number
   * has no staff record, and the page cannot tell those two apart. This endpoint
   * answers the capability question directly and has no side effects — it issues
   * nothing and touches no rows, so it can be called on every page load.
   */
  @Get('dev-login')
  @HttpCode(200)
  @UseGuards(DevLoginGuard)
  devLoginCapability() {
    return { enabled: true };
  }

  /**
   * Development-only. Skips the OTP round trip for a phone that already holds an
   * active staff record.
   *
   * No JwtAuthGuard and no StaffGuard: this IS the sign-in, so there is no token
   * yet to check. The gate is instead the service's own lookup, which requires an
   * existing active staff record, plus the route being unregistered entirely when
   * the flag is off. ADMIN_ROLES is therefore deliberately not applied — there is
   * no principal yet, and the role that matters is re-read from the database by
   * StaffGuard on every request that follows.
   */
  @Post('dev-login')
  @HttpCode(200)
  @UseGuards(DevLoginGuard)
  async devLogin(@Body() dto: RequestOtpDto) {
    return this.dev.signIn(dto.phone);
  }

  /**
   * Temporary fixed-credential login for production field testing.
   *
   * Active only when `TEST_LOGIN_ENABLED=true` (404 otherwise). Accepts the
   * two fixed accounts `passenger/test123` and `staff/test123` (overridable
   * via TEST_* env vars). Issues the SAME JWT + refresh pair as the OTP flow,
   * so everything downstream — JwtAuthGuard, StaffGuard, roles, scoping —
   * is unchanged.
   *
   * DELETE this route, TestLoginService, TestLoginGuard, and the TEST_*
   * env vars once the operator approves SMS delivery.
   */
  @Post('password-login')
  @HttpCode(200)
  @UseGuards(TestLoginGuard)
  async passwordLogin(@Body() dto: PasswordLoginDto) {
    const result = await this.testLogin.signIn(
      dto.username.trim().toLowerCase(),
      dto.password,
    );
    return {
      ok: true,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      expiresIn: result.expiresIn,
      displayName: result.displayName,
      phone: result.phone,
      role: result.role,
    } as const;
  }

  /**
   * Whether the temporary test login is armed. Side-effect-free: issues
   * nothing, so the app can probe it on every sign-in screen without cost.
   */
  @Get('password-login')
  @HttpCode(200)
  @UseGuards(TestLoginGuard)
  passwordLoginCapability() {
    return { enabled: true } as const;
  }

  /**
   * Finds or provisions the account on first successful sign-in.
   *
   * Creating the user and the passenger profile together keeps the data model
   * consistent: a User without a Passenger is not a valid citizen account.
   */
  private async findOrCreateUser(phone: string) {
    const existing = await this.prisma.user.findUnique({ where: { phone } });
    if (existing) {
      return {
        id: existing.id,
        phone: existing.phone,
        displayName: existing.displayName,
      };
    }

    const created = await this.prisma.user.create({
      data: {
        phone,
        phoneVerifiedAt: new Date(),
        status: UserStatus.ACTIVE,
        preferredLocale: 'am',
        passenger: { create: {} },
      },
      select: { id: true, phone: true, displayName: true },
    });
    return created;
  }
}
