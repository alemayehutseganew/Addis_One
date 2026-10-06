import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { PrismaModule } from '../../prisma/prisma.module';
import { JourneyPlannerService } from './journey-planner.service';
import { JourneysController, StopsController } from './journeys.controller';

@Module({
  // PrismaModule is @Global, but importing it explicitly keeps this module
  // readable in isolation and survives that decision being reversed.
  imports: [PrismaModule, AuthModule],
  controllers: [StopsController, JourneysController],
  providers: [JourneyPlannerService],
  exports: [JourneyPlannerService],
})
export class JourneysModule {}
