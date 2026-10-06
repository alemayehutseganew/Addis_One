/** Complaints wiring. AuthModule supplies JwtAuthGuard, StaffGuard and Public. */
import { Module } from '@nestjs/common';
import { PrismaModule } from '../../prisma/prisma.module';
import { AuthModule } from '../auth/auth.module';
import { AssuranceController } from './assurance.controller';
import { AssuranceService } from './assurance.service';

@Module({
  imports: [PrismaModule, AuthModule],
  controllers: [AssuranceController],
  providers: [AssuranceService],
  exports: [AssuranceService],
})
export class AssuranceModule {}