import { Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, timingSafeEqual } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';
import { TokenService, TokenPair } from './token.service';
import { UserStatus } from '@prisma/client';

// Temporary fixed-credential login for production field testing.
//
// WHY: SMS delivery is not yet approved, so OTP cannot reach real phones.
// Two fixed accounts sign in with username + password until then:
//   passenger / test123  -> citizen session (no Staff row)
//   staff / test123      -> staff session (seeded INSPECTOR row)
//
// Credentials come from env (TEST_PASSENGER_*/TEST_STAFF_*), compared with
// timingSafeEqual. Passwords are NOT stored: the expected value lives only
// in env, so a database leak yields nothing.
//
// DELETE THIS FILE, its route, and the TEST_* env vars once OTP is live.
// Search for TEST_LOGIN_ENABLED to find every piece.
@Injectable()
export class TestLoginService {
  private readonly logger = new Logger('TestLogin');

  constructor(
    private readonly prisma: PrismaService,
    private readonly tokens: TokenService,
    private readonly config: ConfigService,
  ) {}

  async signIn(
    username: string,
    password: string,
  ): Promise<
    TokenPair & { phone: string; displayName: string | null; role: string }
  > {
    const passengerUsername = this.config.get<string>(
      'TEST_PASSENGER_USERNAME',
      'passenger',
    );
    const passengerPassword = this.config.get<string>(
      'TEST_PASSENGER_PASSWORD',
      'test123',
    );
    const staffUsername = this.config.get<string>(
      'TEST_STAFF_USERNAME',
      'staff',
    );
    const staffPassword = this.config.get<string>(
      'TEST_STAFF_PASSWORD',
      'test123',
    );

    const wantsPassenger = this.safeEqual(username, passengerUsername);
    const wantsStaff = this.safeEqual(username, staffUsername);

    if (wantsPassenger && this.safeEqual(password, passengerPassword)) {
      return this.signInPassenger(passengerUsername);
    }
    if (wantsStaff && this.safeEqual(password, staffPassword)) {
      return this.signInStaff(staffUsername);
    }

    // One message for every failure: distinguishing bad username from bad
    // password halves the attacker's search space.
    this.logger.warn(
      `[TEST LOGIN] failed sign-in for username="${username}" — ` +
        'TEST_LOGIN_ENABLED is on; remove it once OTP delivery is live.',
    );
    throw new UnauthorizedException('Invalid username or password');
  }

  // Citizen session for the fixed passenger account, mapped to a stable
  // phone (+251911000100) outside the seeded staff range. Provisioned on
  // first use with a Passenger row, mirroring verify-otp's findOrCreateUser.
  private async signInPassenger(username: string) {
    const phone =
      this.config.get<string>('TEST_PASSENGER_PHONE') ?? '+251911000100';
    const existing = await this.prisma.user.findUnique({ where: { phone } });
    const user =
      existing ??
      (await this.prisma.user.create({
        data: {
          phone,
          phoneVerifiedAt: new Date(),
          displayName: 'Test Passenger',
          status: UserStatus.ACTIVE,
          preferredLocale: 'am',
          passenger: { create: {} },
        },
        select: { id: true, phone: true, displayName: true },
      }));

    this.logger.warn(
      `[TEST LOGIN] issued a CITIZEN session for "${username}" — ` +
        'temporary credential; remove once OTP delivery is live.',
    );
    const pair = await this.tokens.issueFor(user.id, user.phone);
    return {
      ...pair,
      phone: user.phone,
      displayName: user.displayName,
      role: 'passenger' as const,
    };
  }

  // Staff session bound to the seeded INSPECTOR row (+251911000009). An
  // inspector can scan — what field testing needs — but cannot touch fares,
  // revenue, or staff management. Fails closed when that row is missing
  // rather than downgrading to citizen: a silent downgrade would strand the
  // tester on the wrong half of the app with no explanation.
  private async signInStaff(username: string) {
    const phone =
      this.config.get<string>('TEST_STAFF_PHONE') ?? '+251911000009';
    const staff = await this.prisma.staff.findFirst({
      where: { user: { phone }, isActive: true, terminatedAt: null },
      select: {
        userId: true,
        role: true,
        user: { select: { phone: true, displayName: true } },
      },
    });
    if (!staff) {
      this.logger.warn(
        `[TEST LOGIN] staff sign-in refused: no active staff row for ${phone}`,
      );
      throw new UnauthorizedException('Invalid username or password');
    }

    this.logger.warn(
      `[TEST LOGIN] issued a STAFF session for "${username}" as ${staff.role} — ` +
        'temporary credential; remove once OTP delivery is live.',
    );
    const pair = await this.tokens.issueFor(staff.userId, staff.user.phone);
    return {
      ...pair,
      phone: staff.user.phone,
      displayName: staff.user.displayName,
      role: staff.role,
    };
  }

  // Constant-time comparison. Both sides are hashed first so different
  // lengths do not throw: timingSafeEqual needs equal-length buffers, and
  // padding the shorter side would leak the length difference anyway.
  private safeEqual(a: string, b: string): boolean {
    const ha = createHash('sha256').update(a).digest();
    const hb = createHash('sha256').update(b).digest();
    return ha.length === hb.length && timingSafeEqual(ha, hb);
  }
}
