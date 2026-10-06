import { Controller, Get, HttpStatus, Res } from '@nestjs/common';
import type { Response } from 'express';
import { PrismaService } from './prisma/prisma.service';
import { Public } from './modules/auth/jwt-auth.guard';

/**
 * Liveness and readiness.
 *
 * Public, and deliberately does more than return 200: a database that is
 * unreachable looks identical to a running server from the outside, and "the
 * backend is up" is exactly the question being asked when someone is
 * debugging a phone that cannot load a stop list. The database check turns
 * that ambiguity into an answer.
 */
@Controller('health')
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  @Public()
  async check(@Res({ passthrough: true }) res: Response) {
    const checks: Record<string, 'ok' | 'failed'> = { api: 'ok' };
    let healthy = true;

    try {
      // A trivial round-trip, not a count: the point is reachability, and a
      // full table scan would make a health check expensive under load.
      await this.prisma.$queryRaw`SELECT 1`;
      checks.database = 'ok';
    } catch {
      checks.database = 'failed';
      healthy = false;
    }

    // A process that is alive but cannot reach its database is not healthy.
    // The status code matters: monitors act on it, whereas a 200 with
    // "degraded" in the body is routinely read as success.
    if (!healthy) res.status(HttpStatus.SERVICE_UNAVAILABLE);

    return {
      status: healthy ? 'ok' : 'degraded',
      service: 'addis-one-api',
      checks,
    };
  }
}
