import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { VehiclesController } from './vehicles.controller';

@Module({
  imports: [AuthModule],
  controllers: [VehiclesController],
})
export class VehiclesModule {}