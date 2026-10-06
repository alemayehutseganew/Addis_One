/**
 * Seeds real Addis Ababa transport data.
 *
 * Re-runnable: every record is upserted by its natural key, so the script can
 * be applied repeatedly without duplicating rows.
 *
 * Fare rules are seeded in TWO versions for one key on purpose. `CITY-BUS-v1`
 * is SUPERSEDED and `CITY-BUS-v2` is ACTIVE. That is not decoration — it is what
 * makes invariant I3 testable: a ticket issued before the change pins v1, and
 * the same route today quotes v2, so the historical charge stays explicable.
 */
import {
  PrismaClient,
  FareRuleStatus,
  OperatorStatus,
  StaffRole,
  TransportMode,
  UserStatus,
} from '@prisma/client';

const prisma = new PrismaClient();

/** Real coordinates for central Addis Ababa. */
const STOPS = [
  { code: 'PZA',  name: 'Piazza',            nameAm: 'ፓያዛ',         lat: 9.03200, lng: 38.74690, zone: 'Z1', shelter: true },
  { code: 'DGS',  name: 'Derg Square',        nameAm: 'ደርግ አደካ',      lat: 9.01800, lng: 38.75600, zone: 'Z2', shelter: true },
  { code: 'MER',  name: 'Merkato',            nameAm: 'መርካቶ',         lat: 9.01500, lng: 38.75700, zone: 'Z2', shelter: true },
  { code: 'MEG',  name: 'Megenagna',          nameAm: 'መገናኛ',         lat: 9.01970, lng: 38.75640, zone: 'Z2', shelter: false },
  { code: 'ARD',  name: 'Arada',              nameAm: 'አራዳ',          lat: 9.02900, lng: 38.74930, zone: 'Z1', shelter: true },
  { code: 'PIA',  name: 'Piassa',             nameAm: 'ፒያሳ',          lat: 9.02640, lng: 38.73440, zone: 'Z1', shelter: true },
  { code: 'MEX',  name: 'Mexico',             nameAm: 'ሜክሲኮ',         lat: 9.02800, lng: 38.76000, zone: 'Z2', shelter: false },
  { code: 'STG',  name: 'St. George Cathedral', nameAm: 'ቅዱስ ጊዮርጊስ', lat: 9.02030, lng: 38.75250, zone: 'Z2', shelter: true },
  { code: 'LGR',  name: 'La Gare',            nameAm: 'ላ ጋር',          lat: 9.03000, lng: 38.75000, zone: 'Z1', shelter: true },
  { code: 'TAI',  name: 'Taito',              nameAm: 'ታይቶ',          lat: 9.03700, lng: 38.75000, zone: 'Z1', shelter: false },
  { code: 'BOR',  name: 'Bole',               nameAm: 'ቦሌ',           lat: 9.01440, lng: 38.79690, zone: 'Z3', shelter: true },
  { code: 'BMH',  name: 'Bole Medhanialem',   nameAm: 'ቦሌ ምድሓንያሌም',     lat: 9.01970, lng: 38.79060, zone: 'Z3', shelter: true },
  { code: 'KIR',  name: 'Kirkos',             nameAm: 'ክርቆስ',          lat: 9.05000, lng: 38.75000, zone: 'Z4', shelter: true },
  { code: 'GEF',  name: 'Gefersa',            nameAm: 'ጌፋርሳ',          lat: 9.06000, lng: 38.72000, zone: 'Z4', shelter: false },
  { code: 'KAL',  name: 'Kality',             nameAm: 'ካሊቲ',          lat: 8.98000, lng: 38.80000, zone: 'Z3', shelter: false },
] as const;

/** Ordered stops per route, with cumulative distance from the origin. */
const ROUTES = [
  {
    code: 'R-12', name: 'Route 12', nameAm: 'መስመር 12',
    stops: ['PZA', 'ARD', 'MEX', 'LGR', 'TAI', 'KIR'],
    // Distance accumulates in metres; ~10.5 km end to end.
    distances: [0, 900, 2600, 4200, 6100, 8600, 10500],
  },
  {
    code: 'R-3', name: 'Route 3', nameAm: 'መስመር 3',
    stops: ['PZA', 'DGS', 'MER', 'MEG', 'STG', 'MEX', 'BMH'],
    distances: [0, 700, 1500, 2300, 3100, 4200, 6400],
  },
  {
    code: 'R-7', name: 'Route 7', nameAm: 'መስመር 7',
    stops: ['DGS', 'MEG', 'MER', 'MEX', 'BMH', 'BOR'],
    distances: [0, 900, 1700, 2500, 4400, 6200, 7100],
  },
  {
    code: 'R-4', name: 'Route 4', nameAm: 'መስመር 4',
    stops: ['PIA', 'ARD', 'PZA', 'ARD', 'LGR', 'TAI'],
    distances: [0, 1400, 2500, 3600, 4400, 5800],
  },
  {
    code: 'R-5', name: 'Route 5', nameAm: 'መስመር 5',
    stops: ['KIR', 'TAI', 'LGR', 'ARD', 'DGS', 'MEG', 'MEX'],
    distances: [0, 1600, 2900, 4200, 5500, 6300, 7000],
  },
  {
    code: 'R-14', name: 'Route 14', nameAm: 'መስመር 14',
    stops: ['MER', 'MEG', 'BMH', 'BOR', 'KAL'],
    distances: [0, 800, 3400, 5000, 6500, 9000],
  },
] as const;

async function main() {
  console.log('Seeding Addis Ababa transport data...\n');

  // ── Operators ────────────────────────────────────────────────────────────
  const selassie = await prisma.operator.upsert({
    where: { code: 'SELASSIE-1' },
    update: {},
    create: {
      code: 'SELASSIE-1',
      name: 'Selassie I & Shebus',
      status: OperatorStatus.ACTIVE,
      contactPhone: '+251115570000',
      contactEmail: 'ops@selassie1.example.et',
      address: 'Addis Ababa, Ethiopia',
      licenseNumber: 'AA-TRN-001',
    },
  });

  const or = await prisma.operator.upsert({
    where: { code: 'OR-GRAND' },
    update: {},
    create: {
      code: 'OR-GRAND',
      name: 'Grand Ethiopian Bus Lines',
      status: OperatorStatus.ACTIVE,
      contactPhone: '+251115570001',
      contactEmail: 'ops@gebl.example.et',
      address: 'Addis Ababa, Ethiopia',
      licenseNumber: 'AA-TRN-002',
    },
  });
  console.log(`operators: 2 (${selassie.code}, ${or.code})`);

  // ── Stops ────────────────────────────────────────────────────────────────
  const stopId = new Map<string, string>();
  for (const s of STOPS) {
    const row = await prisma.stop.upsert({
      where: { code: s.code },
      update: {
        name: s.name,
        nameAm: s.nameAm,
        latitude: s.lat,
        longitude: s.lng,
        zone: s.zone,
        hasShelter: s.shelter,
      },
      create: {
        code: s.code,
        name: s.name,
        nameAm: s.nameAm,
        latitude: s.lat,
        longitude: s.lng,
        zone: s.zone,
        hasShelter: s.shelter,
        isActive: true,
      },
    });
    stopId.set(s.code, row.id);
  }
  console.log(`stops: ${STOPS.length}`);

  // ── Routes and ordered stops ─────────────────────────────────────────────
  let routeCount = 0;
  for (const r of ROUTES) {
    const route = await prisma.route.upsert({
      where: { code_operatorId: { code: r.code, operatorId: selassie.id } },
      update: {
        name: r.name,
        nameAm: r.nameAm,
        distanceMeters: r.distances[r.distances.length - 1],
      },
      create: {
        code: r.code,
        name: r.name,
        nameAm: r.nameAm,
        mode: TransportMode.BUS,
        operatorId: selassie.id,
        distanceMeters: r.distances[r.distances.length - 1],
        // A bus doing ~22 km/h through city traffic.
        typicalDurationSeconds: Math.round(
          (r.distances[r.distances.length - 1] / 1000 / 22) * 3600,
        ),
      },
    });

    // Replace rather than merge: ordering is part of the route's identity, and
    // a stale sequence would silently corrupt every itinerary built from it.
    await prisma.routeStop.deleteMany({ where: { routeId: route.id } });
    for (let i = 0; i < r.stops.length; i++) {
      await prisma.routeStop.create({
        data: {
          routeId: route.id,
          stopId: stopId.get(r.stops[i]),
          sequence: i,
          distanceFromStartMeters: r.distances[i],
        },
      });
    }
    routeCount++;
  }
  console.log(`routes: ${routeCount}`);

  // ── Fare rules ────────────────────────────────────────────────────────────
  //
  // Amounts are integer fils. 100 fils = 1 ETB, so 1500 = ETB 15.00.
  //
  // Zone-pair rules with a distance ceiling. Specificity is resolved by the
  // fare engine (route > operator > zone pair > distance band > citywide), so
  // the ordering here does not matter — only the data does.
  const effectiveFrom = new Date('2026-01-01T00:00:00Z');

  type RuleSeed = {
    ruleKey: string;
    version: number;
    originZone?: string;
    destinationZone?: string;
    distanceToMeters?: number;
    baseFareFils: number;
    perKmFils: number;
    minimumFareFils: number;
    status: FareRuleStatus;
    effectiveUntil?: Date;
    changeReason?: string;
  };

  const rules: RuleSeed[] = [
    // Citywide fallback — least specific, so anything more specific wins.
    {
      ruleKey: 'CITY-BUS', version: 1, baseFareFils: 1000, perKmFils: 200,
      minimumFareFils: 1000, status: FareRuleStatus.SUPERSEDED,
      effectiveUntil: new Date('2026-06-01T00:00:00Z'),
      changeReason: 'Superseded by zone-based pricing approved by the bureau',
    },
    {
      ruleKey: 'CITY-BUS', version: 2, baseFareFils: 1200, perKmFils: 250,
      minimumFareFils: 1200, status: FareRuleStatus.ACTIVE,
      changeReason: 'Bureau fare revision, effective 2026-06-01',
    },

    // Zone pairs — the rules most journeys will actually match.
    { ruleKey: 'ZONE-1-2', version: 1, originZone: 'Z1', destinationZone: 'Z2',
      baseFareFils: 1500, perKmFils: 300, minimumFareFils: 1500,
      status: FareRuleStatus.ACTIVE },
    { ruleKey: 'ZONE-2-1', version: 1, originZone: 'Z2', destinationZone: 'Z1',
      baseFareFils: 1500, perKmFils: 300, minimumFareFils: 1500,
      status: FareRuleStatus.ACTIVE },
    { ruleKey: 'ZONE-1-3', version: 1, originZone: 'Z1', destinationZone: 'Z3',
      baseFareFils: 1500, perKmFils: 280, minimumFareFils: 1500,
      status: FareRuleStatus.ACTIVE },
    { ruleKey: 'ZONE-3-1', version: 1, originZone: 'Z3', destinationZone: 'Z1',
      baseFareFils: 1500, perKmFils: 280, minimumFareFils: 1500,
      status: FareRuleStatus.ACTIVE },
    { ruleKey: 'ZONE-2-3', version: 1, originZone: 'Z2', destinationZone: 'Z3',
      baseFareFils: 1400, perKmFils: 300, minimumFareFils: 1400,
      status: FareRuleStatus.ACTIVE },
    { ruleKey: 'ZONE-3-2', version: 1, originZone: 'Z3', destinationZone: 'Z2',
      baseFareFils: 1400, perKmFils: 300, minimumFareFils: 1400,
      status: FareRuleStatus.ACTIVE },

    // Long-haul band: past 7 km the per-km component dominates the base.
    { ruleKey: 'LONG-DIST', version: 1, distanceToMeters: null,
      baseFareFils: 1800, perKmFils: 220, minimumFareFils: 1800,
      status: FareRuleStatus.ACTIVE },
  ];

  let ruleCount = 0;
  for (const r of rules) {
    await prisma.fareRule.upsert({
      where: { ruleKey_version: { ruleKey: r.ruleKey, version: r.version } },
      update: {
        baseFareFils: r.baseFareFils,
        perKmFils: r.perKmFils,
        minimumFareFils: r.minimumFareFils,
        status: r.status,
        changeReason: r.changeReason,
      },
      create: {
        ruleKey: r.ruleKey,
        version: r.version,
        mode: TransportMode.BUS,
        originZone: r.originZone ?? null,
        destinationZone: r.destinationZone ?? null,
        distanceToMeters: r.distanceToMeters ?? null,
        baseFareFils: r.baseFareFils,
        perKmFils: r.perKmFils,
        minimumFareFils: r.minimumFareFils,
        currency: 'ETB',
        status: r.status,
        effectiveFrom,
        effectiveUntil: r.effectiveUntil ?? null,
        changeReason: r.changeReason ?? null,
      },
    });
    ruleCount++;
  }
  console.log(`fare rules: ${ruleCount} (CITY-BUS v1 superseded, v2 active)`);

  // ── Concessions ──────────────────────────────────────────────────────────
  for (const c of [
    { code: 'STUDENT', name: 'Student', nameAm: 'ተማሪ', discountPercent: 50 },
    { code: 'SENIOR',  name: 'Senior',  nameAm: 'ሽያን',  discountPercent: 40 },
    { code: 'DISABILITY', name: 'Disability', nameAm: 'የአካል ጉዳት', discountPercent: 100 },
  ]) {
    await prisma.concession.upsert({
      where: { code: c.code },
      update: { discountPercent: c.discountPercent },
      create: {
        code: c.code,
        name: c.name,
        nameAm: c.nameAm,
        // DISABILITY has 100 = full exemption, expressed as a 100% discount.
        discountPercent: c.discountPercent,
        requiresProof: true,
        isActive: true,
      },
    });
  }
  console.log('concessions: 3');

  // ── Transfer rule ────────────────────────────────────────────────────────
  await prisma.transferRule.upsert({
    where: { code: 'STD-TRANSFER' },
    update: {},
    create: {
      code: 'STD-TRANSFER',
      name: 'Standard transfer discount',
      withinMinutes: 60,
      discountPercent: 80, // second leg costs 20% less
      maxTransfers: 1,
      appliesToModes: [TransportMode.BUS],
      isActive: true,
    },
  });
  console.log('transfer rules: 1');

  // ── Staff accounts ────────────────────────────────────────────────────────
  //
  // Seeded so the office dashboard is reachable without hand-editing the
  // database. Without at least one Staff row every /dashboard/* route 403s,
  // which is correct but leaves the reporting surface untestable.
  //
  // These sign in with the SAME OTP flow as a citizen: the phone is verified,
  // the JWT is identical, and StaffGuard is what separates the two. There is no
  // separate staff login, deliberately — one credential store and one token
  // path means one thing to revoke and one place a bug can hide.
  const staffSeed: Array<{
    phone: string;
    displayName: string;
    role: StaffRole;
    employeeCode: string;
    operatorId: string | null;
  }> = [
    {
      phone: '+251911000001',
      displayName: 'Bureau Administrator',
      role: StaffRole.TRANSPORT_BUREAU_ADMIN,
      employeeCode: 'TB-001',
      // Bureau-level: sees every operator's figures. Attaching an operator here
      // would be ignored by design, since the role is the grant.
      operatorId: null,
    },
    {
      phone: '+251911000002',
      displayName: 'Finance Officer',
      role: StaffRole.FINANCE,
      employeeCode: 'TB-002',
      operatorId: null,
    },
    {
      phone: '+251911000003',
      displayName: 'Selassie I Operations',
      role: StaffRole.OPERATOR_ADMIN,
      employeeCode: 'TB-003',
      // Deliberately scoped, so the operator-scoping path is exercised by a real
      // login rather than only by tests.
      operatorId: selassie.id,
    },
    // ── City-wide oversight roles ───────────────────────────────────────────
    {
      phone: '+251911000004',
      displayName: 'System Super Administrator',
      role: StaffRole.SUPER_ADMIN,
      employeeCode: 'TB-004',
      operatorId: null,
    },
    {
      phone: '+251911000005',
      displayName: 'Internal Auditor',
      role: StaffRole.AUDITOR,
      employeeCode: 'TB-005',
      // An auditor reads across every operator. Narrowing this account would
      // defeat the point of an audit.
      operatorId: null,
    },
    // ── Field and line roles, scoped to one operator ────────────────────────
    // Every operational role is attached to Selassie I. That is not decoration:
    // operatorScope() narrows these five roles to their operatorId, so each one
    // is a live test that a field account cannot read or write another
    // operator's fleet. Without an account per role there is nothing to log in
    // as, and the staff-facing endpoints cannot be exercised at all.
    {
      phone: '+251911000006',
      displayName: 'Selassie I Supervisor',
      role: StaffRole.SUPERVISOR,
      employeeCode: 'TB-006',
      operatorId: selassie.id,
    },
    {
      phone: '+251911000007',
      displayName: 'Selassie I Driver',
      role: StaffRole.DRIVER,
      employeeCode: 'TB-007',
      operatorId: selassie.id,
    },
    {
      phone: '+251911000008',
      displayName: 'Selassie I Conductor',
      role: StaffRole.CONDUCTOR,
      employeeCode: 'TB-008',
      operatorId: selassie.id,
    },
    {
      phone: '+251911000009',
      displayName: 'Selassie I Inspector',
      role: StaffRole.INSPECTOR,
      employeeCode: 'TB-009',
      operatorId: selassie.id,
    },
    {
      phone: '+251911000010',
      displayName: 'Selassie I Ticket Officer',
      role: StaffRole.TICKET_OFFICER,
      employeeCode: 'TB-010',
      operatorId: selassie.id,
    },
    {
      phone: '+251911000011',
      displayName: 'Selassie I Agent',
      role: StaffRole.AGENT,
      employeeCode: 'TB-011',
      operatorId: selassie.id,
    },
  ];

  // Retained so the fleet section below can bind a Driver record to the staff
  // account that actually signs in. Without this a Driver would be an orphan row
  // that no login could ever reach, and the driver endpoints could not be tested.
  const seededUserIds = new Map<string, string>();

  for (const s of staffSeed) {
    const user = await prisma.user.upsert({
      where: { phone: s.phone },
      update: { displayName: s.displayName },
      create: {
        phone: s.phone,
        phoneVerifiedAt: new Date(),
        displayName: s.displayName,
        status: UserStatus.ACTIVE,
        preferredLocale: 'en',
        // A staff member is not a citizen, so no Passenger row is created.
        // The schema separates them precisely so citizen-only fields do not
        // appear on the staff table.
      },
    });

    await prisma.staff.upsert({
      where: { userId: user.id },
      update: {
        role: s.role,
        employeeCode: s.employeeCode,
        operatorId: s.operatorId,
        isActive: true,
        terminatedAt: null,
      },
      create: {
        userId: user.id,
        role: s.role,
        employeeCode: s.employeeCode,
        operatorId: s.operatorId,
        isActive: true,
        hiredAt: new Date('2026-01-01T00:00:00Z'),
      },
    });
    seededUserIds.set(s.phone, user.id);
  }
  console.log(`staff: ${staffSeed.length} accounts across all 11 roles`);

  // ── Fleet, drivers and today's trips ───────────────────────────────────────
  // Without these the driver endpoints have nothing to act on: the dashboard's
  // operational figures come from Trip rows, and a driver signing in finds an
  // empty list. The vehicles are deliberately split across BOTH operators so that
  // operator scoping has something real to deny — a cross-operator trip that a
  // Selassie I driver can see would make the scoping test pass for the wrong
  // reason.
  const fleetSeed = [
    { plate: 'ET-AA-1001', operator: selassie, mode: 'BUS' as const, capacity: 45 },
    { plate: 'ET-AA-1002', operator: selassie, mode: 'BUS' as const, capacity: 45 },
    { plate: 'ET-AA-1003', operator: selassie, mode: 'BUS' as const, capacity: 30 },
    // A second operator's bus. Its presence is what makes a leaked trip
    // detectable.
    { plate: 'ET-BB-2001', operator: or, mode: 'BUS' as const, capacity: 50 },
  ];

  const vehicles = [];
  for (const v of fleetSeed) {
    vehicles.push(
      await prisma.vehicle.upsert({
        where: { code: v.plate },
        create: {
          code: v.plate,
          operatorId: v.operator.id,
          mode: v.mode,
          make: 'Ethiopian',
          model: 'City Bus',
          capacity: v.capacity,
          fareFils: 4400,
        },
        update: { operatorId: v.operator.id, capacity: v.capacity },
      }),
    );
  }
  console.log(`vehicles: ${vehicles.length} (across ${fleetSeed.length === 4 ? 2 : 1} operators)`);

  // Create VehicleQrCredentials so passengers can scan and pay on the vehicle
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000); // 1 year
  const vehicleQrCredentials = [];
  for (const v of vehicles) {
    vehicleQrCredentials.push(
      await prisma.vehicleQrCredential.upsert({
        where: { id: v.id }, // Using vehicle ID as credential ID for simplicity
        create: {
          id: v.id,
          vehicleId: v.id,
          payload: JSON.stringify({ vehicleCode: v.code, vehicleId: v.id, operatorId: v.operatorId }),
          issuedAt: now,
          expiresAt,
        },
        update: { payload: JSON.stringify({ vehicleCode: v.code, vehicleId: v.id, operatorId: v.operatorId }), expiresAt },
      }),
    );
  }
  console.log(`vehicle QR credentials: ${vehicleQrCredentials.length}`);

  const driverUserId = seededUserIds.get('+251911000007') ?? null;
  const driver = await prisma.driver.upsert({
    where: { licenseNumber: 'DL-SEL-0001' },
    create: {
      licenseNumber: 'DL-SEL-0001',
      operatorId: selassie.id,
      // Bound to the DRIVER staff account, so the seeded login drives this
      // driver's trips rather than an unowned record.
      userId: driverUserId,
      phone: '+251911000007',
    },
    update: { operatorId: selassie.id, userId: driverUserId },
  });
  console.log(`drivers: 1 (${driver.licenseNumber})`);

  // Trips are rebuilt on every seed. Trip is keyed by
  // (vehicleId, tripSequence, scheduledDeparture), and departures are generated
  // relative to "now" — so an upsert would accumulate a growing set of stale
  // trips from previous runs. Clearing the seeded vehicles first keeps re-seeding
  // idempotent and the driver list honest.
  await prisma.trip.deleteMany({
    where: { vehicleId: { in: vehicles.map((v) => v.id) } },
  });

  const selassieRoutes = await prisma.route.findMany({
    where: { operatorId: selassie.id, isActive: true },
    orderBy: { code: 'asc' },
  });
  const grandRoutes = await prisma.route.findMany({
    where: { operatorId: or.id, isActive: true },
    orderBy: { code: 'asc' },
  });

  // Departures are placed relative to the current hour so the driver's list is
  // populated whenever the seed is run, rather than only at a fixed wall-clock
  // time that would be empty in the evening.
  const hourNow = new Date().getUTCHours();
  const slots = [
    { offset: -2, status: 'COMPLETED' as const },
    { offset: -1, status: 'COMPLETED' as const },
    { offset: 0, status: 'IN_PROGRESS' as const },
    { offset: 1, status: 'BOARDING' as const },
    { offset: 3, status: 'SCHEDULED' as const },
  ];

  let tripCount = 0;
  for (const slot of slots) {
    const route = selassieRoutes[tripCount % selassieRoutes.length];
    const vehicle = vehicles[0];
    if (!route) break;

    const scheduled = new Date();
    scheduled.setUTCHours(Math.max(0, Math.min(23, hourNow + slot.offset)), 0, 0, 0);
    const scheduledArrival = new Date(scheduled.getTime() + 45 * 60_000);

    await prisma.trip.create({
      data: {
        routeId: route.id,
        vehicleId: vehicle.id,
        driverId: driver.id,
        operatorId: selassie.id,
        tripSequence: 1 + tripCount,
        direction: 'OUTBOUND',
        scheduledDeparture: scheduled,
        scheduledArrival,
        status: slot.status,
        // Completed runs carry real times so delay figures are not all null and
        // the dashboard has something to average.
        actualDeparture:
          slot.status === 'SCHEDULED' || slot.status === 'BOARDING'
            ? null
            : new Date(scheduled.getTime() + 4 * 60_000),
        actualArrival:
          slot.status === 'COMPLETED'
            ? new Date(scheduledArrival.getTime() + 6 * 60_000)
            : null,
        delaySeconds: slot.status === 'COMPLETED' ? 360 : null,
      },
    });
    tripCount++;
  }

  // One trip belonging to the second operator, which the Selassie I driver must
  // never be able to start, complete, or read a manifest from.
  //
  // Every route in the ROUTES seed belongs to Selassie I, so this creates the
  // second operator's route here rather than assuming one exists. Without it the
  // cross-operator trip is silently skipped and operator scoping has nothing to
  // deny — a test that passes because nothing was there to leak.
  const foreignRoute =
    grandRoutes[0] ??
    (await prisma.route.upsert({
      where: { code_operatorId: { code: 'GRAND-1', operatorId: or.id } },
      create: {
        code: 'GRAND-1',
        name: 'Grand Ethiopian Airport Express',
        mode: 'BUS',
        operatorId: or.id,
        distanceMeters: 18_400,
        typicalDurationSeconds: 2_700,
      },
      update: { isActive: true },
    }));
  const foreignVehicle = vehicles[3];
  if (foreignRoute && foreignVehicle) {
    const scheduled = new Date();
    scheduled.setUTCHours(Math.max(0, Math.min(23, hourNow)), 0, 0, 0);
    await prisma.trip.create({
      data: {
        routeId: foreignRoute.id,
        vehicleId: foreignVehicle.id,
        operatorId: or.id,
        tripSequence: 1,
        direction: 'OUTBOUND',
        scheduledDeparture: new Date(scheduled.getTime() + 2 * 60 * 60_000),
        status: 'SCHEDULED',
      },
    });
    tripCount++;
  }

  console.log(`trips: ${tripCount} (today, incl. 1 from the other operator)`);

  console.log('\nSeed complete.');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
