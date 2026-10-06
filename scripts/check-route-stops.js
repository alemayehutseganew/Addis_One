// Diagnostic: do the seeded routes actually have stops attached, and are the
// stops unique? The cash-sale test stalls when the planner returns no
// purchasable option, and the question is whether that is a planner problem or a
// seed gap. Written as a script because a `node -e` one-liner loses its quotes
// to cmd, which previously produced parser errors masquerading as results.
const { PrismaClient } = require('../backend/node_modules/@prisma/client');
const prisma = new PrismaClient();

(async () => {
  const routes = await prisma.route.findMany({
    include: { _count: { select: { stops: true } } },
  });
  console.log('routes:');
  for (const r of routes) {
    console.log(`  ${r.code.padEnd(12)} operator=${r.operatorId.slice(0, 8)} stops=${r._count.stops}`);
  }

  const stopCount = await prisma.stop.count();
  const legs = await prisma.routeStop.findMany({
    take: 40,
    orderBy: { sequence: 'asc' },
    select: { routeId: true, stopId: true, sequence: true },
  });
  console.log(`\nstops total: ${stopCount}`);
  console.log(`route-stop links: ${legs.length}`);
  const byRoute = new Map();
  for (const l of legs) byRoute.set(l.routeId, (byRoute.get(l.routeId) || 0) + 1);
  console.log('links per route:');
  for (const [id, n] of byRoute) console.log(`  ${id.slice(0, 8)} -> ${n}`);

  const stops = await prisma.stop.findMany({ take: 5, select: { id: true, code: true } });
  console.log('\nsample stops:');
  for (const s of stops) console.log(`  ${s.code} ${s.id}`);

  // Emit a pair of stops that share a route in sequence order. The planner only
  // connects such pairs, so any other two stops are legitimately unroutable and
  // using them in an end-to-end test produces a false negative.
  const route = await prisma.route.findFirst({
    where: { stops: { some: {} } },
    orderBy: { code: 'asc' },
    include: { stops: { orderBy: { sequence: 'asc' }, take: 2, select: { stopId: true, sequence: true } } },
  });
  console.log('\nROUTABLE_PAIR=' + JSON.stringify({
    route: route?.code,
    origin: route?.stops[0]?.stopId,
    destination: route?.stops[1]?.stopId,
  }));
})()
  .finally(() => prisma.$disconnect());