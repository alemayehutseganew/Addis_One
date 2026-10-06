import { Module } from '@nestjs/common';
import { AdminController } from './admin.controller';
import { AdminService } from './admin.service';
import { AuthModule } from '../auth/auth.module';
import { PrismaModule } from '../../prisma/prisma.module';

@Module({
  // AuthModule supplies the guards this controller composes; PrismaModule
  // supplies PrismaService directly rather than through DashboardModule, so the
  // admin surface does not depend on the read-only reporting module being loaded.
  imports: [PrismaModule, AuthModule],
  controllers: [AdminController],
  providers: [AdminService],
})
export class AdminModule {}