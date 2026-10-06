import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DatabaseInspectorService } from './database-inspector.service';
import { DashboardController } from './dashboard.controller';
import { DashboardService } from './dashboard.service';

/**
 * Government/office reporting.
 *
 * AuthModule is imported for JwtAuthGuard and StaffGuard, which the controller
 * composes. PrismaModule is @Global, so the service needs no explicit import.
 */
@Module({
  imports: [AuthModule],
  controllers: [DashboardController],
  providers: [DashboardService, DatabaseInspectorService],
})
export class DashboardModule {}
