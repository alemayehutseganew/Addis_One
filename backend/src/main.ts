import { Logger, RequestMethod, ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import type { NestExpressApplication } from '@nestjs/platform-express';
import type { NextFunction, Request, Response } from 'express';
import helmet from 'helmet';
import { join } from 'node:path';
import { AppModule } from './app.module';
import { PrismaService } from './prisma/prisma.service';
import { assertValidConfig, redact } from './config/validate-env';
import { config as loadEnvFile } from 'dotenv';

/**
 * Logs one line per request: method, path, status, duration.
 *
 * Without this the server log contains only Nest's startup banner, so a phone
 * failing to reach an endpoint leaves no trace at all — the absence of a line
 * proves nothing, and debugging on-device means guessing. Written against the
 * Express types already present rather than adding a dependency for six lines.
 *
 * Health checks are dropped: the device and the polling scripts call it
 * constantly, and letting it scroll past would bury the requests being hunted.
 */
function requestLogger() {
  const logger = new Logger('HTTP');
  return (req: Request, res: Response, next: NextFunction): void => {
    if (req.path === '/api/v1/health') return next();
    const startedAt = process.hrtime.bigint();
    res.on('finish', () => {
      const ms = Number(process.hrtime.bigint() - startedAt) / 1e6;
      logger.log(
        `${req.method} ${req.originalUrl} ${res.statusCode} ${ms.toFixed(1)}ms`,
      );
    });
    next();
  };
}

async function bootstrap() {
  // Before anything touches the database. Prisma reports a bad connection string
  // from deep inside its client as "the validation schema for datasource `db`
  // specifies provider = postgresql, but the resolved URL is mysql://…", which
  // points an operator at schema.prisma rather than at the environment variable
  // they actually set. Checking here lets the message name the variable, name the
  // competing source, and redact the password.
  //
  // .env is loaded HERE, first, and deliberately not left to ConfigModule.
  // ConfigModule.forRoot() only reads .env while NestFactory.create() builds the
  // DI container, which is several lines below — so a guard placed before that
  // sees an empty process.env and rejects a perfectly good .env. The guard would
  // then only work for deployments that export every variable themselves, and
  // would report a correct config file as missing.
  //
  // override is left at its default (false) on purpose: a value genuinely
  // exported by the operator must still win over a file on disk. That is exactly
  // the case this guard exists to diagnose, so silently preferring .env would
  // hide it.
  loadEnvFile({ path: join(__dirname, '..', '.env') });

  assertValidConfig();
  new Logger('Config').log(
    `DATABASE_URL resolves to ${redact(process.env.DATABASE_URL as string)}`,
  );

  // Typed as the Express application because that is what the process actually
  // is, and useStaticAssets is an Express-adapter method that the base
  // INestApplication interface does not declare.
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: false,
  });
  const config = app.get(ConfigService);
  const logger = new Logger('Bootstrap');

  const allowed = config
    .get<string>('CORS_ORIGINS', 'http://localhost:3000,http://localhost:8081')
    .split(',')
    .map((o) => o.trim());
  app.enableCors({ origin: allowed, credentials: true });

  // helmet's default Content-Security-Policy includes
  // `upgrade-insecure-requests`, which tells the browser to rewrite every
  // http:// subresource to https://. On a TLS-terminating production proxy that
  // is correct and desirable. Against this plain-HTTP dev server it is fatal:
  // the browser silently upgrades /dashboard/dashboard.js to https, the request
  // fails, and the page renders as a bare shell with no console error — a
  // failure that looks like a bug in the page and is actually a header.
  //
  // So it is enabled only when the deployment is expected to be secure.
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          ...(config.get<string>('NODE_ENV') === 'production'
            ? {}
            : { upgradeInsecureRequests: null }),
        },
      },
    }),
  );
  // Registered before the routes so every request is timed, and before
  // setGlobalPrefix so the log shows the full public path a client called.
  app.use(requestLogger());

  // Versioned from day one: an unversioned API cannot be changed safely once
  // clients are in the field.
  //
  // Order matters — setGlobalPrefix must run BEFORE listen(), because Nest
  // resolves and registers the route table during bootstrap. Calling it after
  // leaves every route un-prefixed and every request 404s.
  //
  // The dashboard is served from the same process, outside the versioned
  // prefix. Its path is therefore frozen by that choice: /dashboard will not
  // become /api/v2/dashboard on the next version bump, which is exactly what an
  // officer has bookmarked. A separate host or reverse-proxy mount is the
  // alternative if the page must move later.
  app.setGlobalPrefix('api/v1', {
    exclude: [{ path: 'dashboard', method: RequestMethod.GET }],
  });

  // The dashboard is a static page, so it is mounted from disk rather than
  // written as a Nest controller returning a string. A controller would have to
  // embed the HTML in TypeScript, which buys nothing and makes the page
  // impossible to edit or diff as a document.
  //
  // The root is `public/dashboard`, not `public`: useStaticAssets strips the
  // prefix and looks the remainder up relative to the root, so mounting
  // `public` with prefix `/dashboard/` would send `/dashboard/index.html` to
  // `public/index.html` and 404 every request.
  app.useStaticAssets(join(__dirname, '..', 'public', 'dashboard'), {
    prefix: '/dashboard/',
    // Index serves `/dashboard/` directly instead of forcing the file name.
    index: ['index.html'],
    // Served same-origin, so the browser sends the bearer token with no CORS
    // preflight and no wildcard origin has to be permitted. Caching is off
    // deliberately: an officer who has bookmarked this URL must never be shown
    // a stale build of the reporting screen.
    maxAge: 0,
  });

  app.useGlobalPipes(
    new ValidationPipe({
      // Strip unknown fields so a client cannot smuggle extra columns through
      // a DTO into the persistence layer.
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  // ── API documentation ──────────────────────────────────────────────────────
  // `@nestjs/swagger` has been a dependency from the start but was never mounted,
  // which meant the only way to discover a route — including every role-gated one
  // — was to read the controllers. That is exactly how the staff-facing surface
  // went unnoticed as missing.
  //
  // Bearer auth is declared explicitly so the docs page can offer an "Authorize"
  // control; without it the Swagger UI cannot send a token and every guarded route
  // is listed but unusable.
  //
  // Served outside the /api/v1 prefix (SwaggerModule mounts its own routes, which
  // the global prefix does not apply to) and in non-production only.
  if (config.get<string>('NODE_ENV') !== 'production') {
    const openApi = SwaggerModule.createDocument(
      app,
      new DocumentBuilder()
        .setTitle('Addis One API')
        .setDescription(
          'City transport operating and assurance platform. ' +
            'All staff routes require a JWT from /auth/verify-otp and are ' +
            'additionally gated by role.',
        )
        .setVersion('1.0')
        .addBearerAuth({ type: 'http', scheme: 'bearer', bearerFormat: 'JWT' })
        .build(),
    );
    SwaggerModule.setup('api/docs', app, openApi);
  }

  // Bind to every interface so a phone on the same LAN can reach the API.
  // 0.0.0.0 is correct for development behind a firewall; a production
  // deployment should sit behind a reverse proxy that terminates TLS.
  const port = config.get<number>('PORT', 3000);
  await app.listen(port, '0.0.0.0');

  // Close the database before exiting so in-flight requests are not severed
  // mid-transaction.
  app.enableShutdownHooks();

  logger.log(`Addis One API listening on http://0.0.0.0:${port}/api/v1`);
  logger.log(`Operations dashboard: http://localhost:${port}/dashboard/`);
  logger.log(`CORS origins: ${allowed.join(', ')}`);
}

bootstrap().catch((err) => {
  // eslint-disable-next-line no-console
  console.error('Fatal error during bootstrap', err);
  process.exit(1);
});
