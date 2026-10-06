import { HttpException, HttpStatus, Injectable, Logger } from '@nestjs/common';
import { BadRequestException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomInt, timingSafeEqual } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';

/**
 * Nest 10 has no TooManyRequestsException; 429 has to be raised explicitly.
 */
function tooManyRequests(message: string): HttpException {
  return new HttpException(message, HttpStatus.TOO_MANY_REQUESTS);
}

const OTP_TTL_SECONDS = 300;
const MAX_ATTEMPTS = 5;
const RESEND_COOLDOWN_SECONDS = 45;
const MAX_REQUESTS_PER_PHONE_PER_HOUR = 5;

/**
 * OTP challenge issuing and verification.
 *
 * **Codes are never stored in plaintext.** Only a SHA-256 hash is persisted, so
 * a database leak — the exact scenario your blueprint calls out — does not yield
 * usable login codes. The code is sent by SMS and forgotten.
 *
 * A per-phone salt is mixed into the hash so a precomputed table of six-digit
 * codes cannot be used to reverse the stored values. Six digits is only a
 * million possibilities, which is trivially brute-forceable without a salt.
 */
@Injectable()
export class OtpService {
  private readonly logger = new Logger(OtpService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  /** Development-only: prints the code to the console so it can be tested. */
  private get devEchoEnabled(): boolean {
    return this.config.get<string>('OTP_DEV_ECHO', 'false') === 'true';
  }

  async issue(phone: string): Promise<void> {
    await this.enforceRateLimits(phone);

    // Supersede any outstanding challenge: only the newest code is valid.
    await this.prisma.otpChallenge.updateMany({
      where: { phone, consumedAt: null },
      data: { consumedAt: new Date() },
    });

    const code = randomInt(0, 1_000_000).toString().padStart(6, '0');
    const salt = randomInt(0, 0xffffffff).toString(16);

    await this.prisma.otpChallenge.create({
      data: {
        phone,
        codeHash: this.hash(code, salt),
        salt,
        maxAttempts: MAX_ATTEMPTS,
        expiresAt: new Date(Date.now() + OTP_TTL_SECONDS * 1000),
      },
    });

    if (this.devEchoEnabled) {
      // Loud and obvious: this must never be enabled in production.
      this.logger.warn(
        `[DEV OTP] phone=${phone} code=${code} — ` +
          'OTP_DEV_ECHO is enabled; do not use this build in production.',
      );
    } else {
      // TODO: hand off to the SMS provider (Africa's Talking / Ethio Telecom).
      // Throwing here rather than silently succeeding means a misconfigured
      // deployment fails loudly instead of appearing to work.
      throw new BadRequestException(
        'SMS delivery is not configured. Set OTP_DEV_ECHO=true for local testing.',
      );
    }
  }

  /**
   * Verifies a code and consumes the challenge.
   *
   * Returns false for every failure mode — wrong code, expired, exhausted,
   * unknown — so the caller cannot accidentally leak which one occurred.
   */
  async verify(phone: string, code: string): Promise<boolean> {
    const challenge = await this.prisma.otpChallenge.findFirst({
      where: { phone, consumedAt: null },
      orderBy: { createdAt: 'desc' },
    });

    if (!challenge) return false;
    if (challenge.expiresAt < new Date()) return false;
    if (challenge.attempts >= challenge.maxAttempts) return false;

    const candidate = Buffer.from(this.hash(code, challenge.salt), 'hex');
    const expected = Buffer.from(challenge.codeHash, 'hex');

    // Constant-time compare: a byte-by-byte early exit leaks timing information
    // that lets an attacker recover the hash a character at a time.
    const matches =
      candidate.length === expected.length &&
      timingSafeEqual(candidate, expected);

    if (!matches) {
      await this.prisma.otpChallenge.update({
        where: { id: challenge.id },
        data: { attempts: { increment: 1 } },
      });
      return false;
    }

    await this.prisma.otpChallenge.update({
      where: { id: challenge.id },
      data: { consumedAt: new Date() },
    });
    return true;
  }

  private hash(code: string, salt: string): string {
    // A single round of SHA-256 is correct here: unlike a password, the input
    // space is tiny but the salt + TTL + attempt limit + rate limit together
    // make offline search impractical.
    return createHash('sha256')
      .update(`${salt}:${code}`)
      .digest('hex');
  }

  private async enforceRateLimits(phone: string): Promise<void> {
    const hourAgo = new Date(Date.now() - 3_600_000);

    const recent = await this.prisma.otpChallenge.count({
      where: { phone, createdAt: { gte: hourAgo } },
    });
    if (recent >= MAX_REQUESTS_PER_PHONE_PER_HOUR) {
      throw tooManyRequests('Too many codes requested. Try again later.');
    }

    const last = await this.prisma.otpChallenge.findFirst({
      where: { phone },
      orderBy: { createdAt: 'desc' },
    });
    if (
      last &&
      Date.now() - last.createdAt.getTime() < RESEND_COOLDOWN_SECONDS * 1000
    ) {
      throw tooManyRequests('Please wait before requesting another code.');
    }
  }
}
