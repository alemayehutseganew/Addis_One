import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { StaffPrincipal } from '../auth/staff.guard';

/**
 * Database-level reporting for the office dashboard.
 *
 * Every figure comes from PostgreSQL's own statistics views rather than from a
 * COUNT per table. That distinction matters: `SELECT count(*)` across 43 tables
 * is 43 real scans, and on a production-sized database it is the single most
 * expensive thing a status page can do. `pg_stat_user_tables` reports the row
 * count the planner already maintains, so this screen costs about as much as a
 * health check.
 *
 * The consequence is stated rather than hidden: these row counts are the
 * planner's estimates. After a bulk load they can be stale until the next
 * autovacuum ANALYZE, so they are a health indicator and not an accounting
 * source. Anything that has to be exact is read from the table itself.
 */
@Injectable()
export class DatabaseInspectorService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Headline health, then the per-table detail.
   *
   * All queries are plain SELECTs against catalog views. Nothing here can write,
   * and nothing reads application rows â€” so there is no path from this screen to
   * a citizen's phone number or national ID.
   */
  async inspect(_staff: StaffPrincipal) {
    const [overview, tables, indexes, growth] = await Promise.all([
      this.overview(),
      this.tables(),
      this.indexes(),
      this.growth(),
    ]);

    return {
      generatedAt: new Date().toISOString(),
      ...overview,
      tables,
      indexes,
      growth,
      // Stated on the response so the UI can say it rather than implying the
      // numbers are exact. pg_stat_statements is not installed on this database,
      // so there is genuinely no slow-query data to show.
      notes: {
        rowCountsAreEstimates: true,
        slowQueriesAvailable: false,
      },
    };
  }

  /** Database size, table/index counts, connection use, and uptime. */
  private async overview() {
    const [db] = await this.prisma.$queryRaw<
      Array<{
        name: string;
        sizeBytes: bigint;
        serverVersion: string;
        startedAt: Date;
      }>
    >(Prisma.sql`
      SELECT
        current_database() AS name,
        pg_database_size(current_database()) AS "sizeBytes",
        current_setting('server_version') AS "serverVersion",
        pg_postmaster_start_time() AS "startedAt"
    `);

    const counts = await this.prisma.$queryRaw<
      Array<{ tables: bigint; indexes: bigint; liveTuples: bigint; deadTuples: bigint }>
    >(Prisma.sql`
      SELECT
        (SELECT count(*)::bigint FROM pg_stat_user_tables) AS tables,
        (SELECT count(*)::bigint FROM pg_stat_user_indexes) AS indexes,
        (SELECT COALESCE(sum(n_live_tup), 0)::bigint FROM pg_stat_user_tables) AS "liveTuples",
        (SELECT COALESCE(sum(n_dead_tup), 0)::bigint FROM pg_stat_user_tables) AS "deadTuples"
    `);

    const connections = await this.prisma.$queryRaw<
      Array<{ total: bigint; max: bigint; idle: bigint; used: bigint }>
    >(Prisma.sql`
      SELECT
        (SELECT setting::bigint FROM pg_settings WHERE name = 'max_connections') AS max,
        count(*)::bigint AS total,
        count(*) FILTER (WHERE state = 'idle')::bigint AS idle,
        count(*) FILTER (WHERE state <> 'idle')::bigint AS used
      FROM pg_stat_activity
      WHERE datname = current_database()
    `);

    const c = counts[0];
    const conn = connections[0];

    return {
      database: {
        name: db.name,
        sizeBytes: Number(db.sizeBytes),
        serverVersion: db.serverVersion,
        // Measured from the postmaster start, so this is how long the server has
        // been up, not this connection. Labelled "server" so it is not misread.
        serverUptimeSeconds: Math.round(
          (Date.now() - new Date(db.startedAt).getTime()) / 1000,
        ),
      },
      objects: {
        tables: Number(c.tables),
        indexes: Number(c.indexes),
        liveTuples: Number(c.liveTuples),
        deadTuples: Number(c.deadTuples),
      },
      connections: {
        total: Number(conn.total),
        used: Number(conn.used),
        idle: Number(conn.idle),
        max: Number(conn.max),
        // A fraction rather than a raw count, so the card can be judged at a
        // glance: a pool near its ceiling is the failure this page exists to
        // catch before it becomes "the site is down".
        utilisation: conn.max > 0 ? Number(conn.total) / Number(conn.max) : 0,
      },
    };
  }
/** Per-table size, row estimate, scan mix and maintenance history. */
  private async tables() {
    const rows = await this.prisma.$queryRaw<
      Array<{
        name: string;
        liveTuples: bigint;
        deadTuples: bigint;
        totalBytes: bigint;
        heapBytes: bigint;
        indexBytes: bigint;
        seqScans: bigint;
        idxScans: bigint;
        lastVacuum: Date | null;
        lastAutovacuum: Date | null;
        lastAnalyze: Date | null;
      }>
    >(Prisma.sql`
      SELECT
        relname AS name,
        n_live_tup AS "liveTuples",
        n_dead_tup AS "deadTuples",
        pg_total_relation_size(relid) AS "totalBytes",
        pg_relation_size(relid) AS "heapBytes",
        GREATEST(pg_total_relation_size(relid) - pg_relation_size(relid), 0) AS "indexBytes",
        seq_scan AS "seqScans",
        idx_scan AS "idxScans",
        last_vacuum AS "lastVacuum",
        last_autovacuum AS "lastAutovacuum",
        last_analyze AS "lastAnalyze"
      FROM pg_stat_user_tables
      ORDER BY pg_total_relation_size(relid) DESC, relname ASC
    `);

    return rows.map((r) => {
      const total = Number(r.totalBytes);
      const seq = Number(r.seqScans);
      const idx = Number(r.idxScans);
      const live = Number(r.liveTuples);
      const dead = Number(r.deadTuples);

      // Most recent completed vacuum of either kind. NULL simply means the
      // table has never been vacuumed, which is normal for a young table and is
      // rendered as "never" rather than left blank.
      const lastVacuum = [r.lastVacuum, r.lastAutovacuum]
        .filter(Boolean)
        .sort((a, b) => new Date(b).getTime() - new Date(a).getTime())[0];

      return {
        name: r.name,
        liveTuples: live,
        deadTuples: dead,
        totalBytes: total,
        heapBytes: Number(r.heapBytes),
        indexBytes: Number(r.indexBytes),
        // A table that is mostly index space usually means an index is doing work
        // the table does not justify.
        indexRatio: total > 0 ? Number(r.indexBytes) / total : 0,
// Below 0.5 means the table is read more by full scan than by index.
        // Neither end is automatically wrong: a small reference table read whole
        // is the normal case for one of these.
        indexUsageRatio: seq + idx > 0 ? idx / (seq + idx) : null,
        // Dead rows are space the table occupies but no longer returns: bloat.
        // This ratio is the signal an operator acts on.
        deadRowRatio: live + dead > 0 ? dead / (live + dead) : 0,
        lastVacuum: lastVacuum ? new Date(lastVacuum).toISOString() : null,
        lastAnalyze: r.lastAnalyze ? new Date(r.lastAnalyze).toISOString() : null,
      };
    });
  }

  /**
   * Non-unique indexes and how often each has been read.
   *
   * An index that has never been read costs write throughput and storage and
   * returns nothing, so listing them is the most actionable thing a database
   * status page can offer. It is deliberately a report and not a remediation
   * tool: dropping an index is a judgement about which queries are about to
   * run, and that belongs to someone who has read the plan — not to a dashboard.
   *
   * Unique and primary indexes are excluded because dropping one changes what
   * the database will accept, which is never a dashboard's decision.
   */
  private async indexes() {
    const rows = await this.prisma.$queryRaw<
      Array<{ name: string; table: string; sizeBytes: bigint; idxScans: bigint }>
    >(Prisma.sql`
      SELECT
        ui.relname AS name,
        t.relname AS table,
        pg_relation_size(ui.relid) AS "sizeBytes",
        ui.idx_scan AS "idxScans"
      FROM pg_stat_user_indexes ui
      JOIN pg_index i ON i.indexrelid = ui.relid
      JOIN pg_class t ON t.oid = i.indrelid
      WHERE NOT i.indisunique
        AND NOT i.indisprimary
      ORDER BY pg_relation_size(ui.relid) DESC
    `);

    return rows.map((r) => ({
      name: r.name,
      table: r.table,
      sizeBytes: Number(r.sizeBytes),
      idxScans: Number(r.idxScans),
      unused: Number(r.idxScans) === 0,
    }));
  }
/**
   * The ten largest tables.
   *
   * Returned as raw bytes rather than pre-ranked percentages, because
   * pg_database_size also counts WAL and catalog overhead: summing the tables
   * would not equal the database size, and a chart whose parts do not add up to
   * the stated whole makes a reader distrust the rest of the page.
   */
  private async growth() {
    const rows = await this.prisma.$queryRaw<
      Array<{ name: string; totalBytes: bigint }>
    >(Prisma.sql`
      SELECT relname AS name, pg_total_relation_size(relid) AS "totalBytes"
      FROM pg_stat_user_tables
      ORDER BY pg_total_relation_size(relid) DESC
      LIMIT 10
    `);

    return rows.map((r) => ({
      name: r.name,
      totalBytes: Number(r.totalBytes),
    }));
  }
}
