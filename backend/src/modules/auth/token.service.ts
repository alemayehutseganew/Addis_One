import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomBytes } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';

const ACCESS_TTL_SECONDS = 900; // 15 minutes
const REFRESH_TTL_SECONDS = 2_592_000; // 30 days

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

/**
 * Issues and validates session tokens.
 *
 * Access tokens are short-lived and stateless. Refresh tokens are opaque random
 * strings stored **hashed**, so a database leak cannot be replayed as a
 * session — the attacker gets hashes, not usable credentials.
 */
@Injectable()
export class TokenService {
  constructor(
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    private readonly prisma: PrismaService,
  ) {}

  async issueFor(
    userId: string,
    phone: string,
    deviceId?: string,
  ): Promise<TokenPair> {
    const accessToken = await this.jwt.signAsync(
      { sub: userId, phone },
      {
        secret: this.config.getOrThrow<string>('JWT_ACCESS_SECRET'),
        expiresIn: ACCESS_TTL_SECONDS,
      },
    );

    const refreshToken = randomBytes(32).toString('base64url');
    await this.prisma.refreshToken.create({
      data: {
        userId,
        tokenHash: this.hash(refreshToken),
        deviceId: deviceId ?? null,
        expiresAt: new Date(Date.now() + REFRESH_TTL_SECONDS * 1000),
      },
    });

    return {
      accessToken,
      refreshToken,
      expiresIn: ACCESS_TTL_SECONDS,
    };
  }

  /**
   * Exchanges a refresh token for a new pair.
   *
   * The old token is revoked as part of the exchange (rotation), so a stolen
   * refresh token is usable at most once and its use is detectable.
   */
  async rotate(refreshToken: string): Promise<TokenPair> {
    const record = await this.prisma.refreshToken.findUnique({
      where: { tokenHash: this.hash(refreshToken) },
    });

    if (!record || record.revokedAt || record.expiresAt < new Date()) {
      throw new UnauthorizedException('Invalid or expired refresh token');
    }

    const user = await this.prisma.user.findUniqueOrThrow({
      where: { id: record.userId },
      select: { id: true, phone: true },
    });

    await this.prisma.refreshToken.update({
      where: { id: record.id },
      data: { revokedAt: new Date() },
    });

    return this.issueFor(user.id, user.phone, record.deviceId ?? undefined);
  }

  async verifyAccess(token: string): Promise<{ sub: string; phone: string }> {
    try {
      return await this.jwt.verifyAsync(token, {
        secret: this.config.getOrThrow<string>('JWT_ACCESS_SECRET'),
      });
    } catch {
      // One message for every failure mode: distinguishing "expired" from
      // "malformed" tells an attacker which part of a forged token to fix.
      throw new UnauthorizedException('Invalid access token');
    }
  }

  async revokeAllFor(userId: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  private hash(token: string): string {
    return createHash('sha256').update(token).digest('hex');
  }
}
