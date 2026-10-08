import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import { PrismaModule } from '../../prisma/prisma.module';
import { AuthController, DevLoginService } from './auth.controller';
import { JwtAuthGuard } from './jwt-auth.guard';
import { DevLoginGuard } from './dev-login.guard';
import { OtpService } from './otp.service';
import { StaffGuard } from './staff.guard';
import { TestLoginGuard } from './test-login.guard';
import { TestLoginService } from './test-login.service';
import { TokenService } from './token.service';

@Module({
  imports: [
    PrismaModule,
    ConfigModule,
    // Registered with no secret: TokenService signs each call using the secret
    // from config, so the signing key is never duplicated in module metadata.
    JwtModule.register({}),
  ],
  controllers: [AuthController],
  providers: [
    OtpService,
    TokenService,
    JwtAuthGuard,
    StaffGuard,
    // DevLoginService backs the controller's dev-login route. Registered
    // unconditionally — the guard decides whether the route may be reached, so
    // the service existing on a server with the flag off is harmless.
    DevLoginService,
    // Plain class, not a factory: DevLoginGuard is named directly in
    // `@UseGuards`, so Nest resolves it from this module's context and it reads
    // DEV_STAFF_LOGIN itself on every call.
    DevLoginGuard,
    // Temporary fixed-credential test login (until SMS is approved).
    // Same shape as DevLoginService: registered always, gated per-call.
    TestLoginService,
    TestLoginGuard,
  ],
  exports: [TokenService, JwtAuthGuard, OtpService, StaffGuard],
})
export class AuthModule {}
