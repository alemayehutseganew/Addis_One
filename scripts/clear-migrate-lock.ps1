$ErrorActionPreference = 'Stop'
$done = "$env:TEMP\addis_dblock.txt"
$dsn  = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend\.env'
$url  = (Get-Content $dsn | Where-Object { $_ -match '^\s*DATABASE_URL=' } | Select-Object -First 1)
$url  = ($url -replace '^\s*DATABASE_URL\s*=\s*"?', '').Trim().Trim('"')

$env:DATABASE_URL = $null
$lines = @("url_present=" + [bool]$url)

# Prisma's migrate takes a session-level advisory lock. If a run is killed
# mid-migration the lock is released with the connection, but a connection stuck
# in a transaction can hold it, and the next run then fails with P1002 while
# the database is perfectly healthy — which reads as "the server is down".
# Clearing pg_locks is safe: the migration table is the real source of truth.
# Uses the generated Prisma client rather than `pg`, which is not a dependency.
# Prisma's $queryRaw is enough to inspect locks and terminate backends, so this
# avoids adding a database driver just for an operational script.
$kill = @'
const { PrismaClient } = require('@prisma/client');
(async () => {
  const c = new PrismaClient();
  const rows = await c.$queryRawUnsafe(`
    SELECT a.pid::int AS pid
    FROM pg_locks a
    JOIN pg_stat_activity b ON a.pid = b.pid
    WHERE a.locktype = 'advisory' AND b.datname = current_database()
  `);
  console.log('advisory_locks=' + rows.length);
  for (const r of rows) {
    // $executeRawUnsafe binds as bigint, and pg_terminate_backend has no
    // bigint overload — the call fails with 42883 unless it is cast to int.
    await c.$executeRawUnsafe('SELECT pg_terminate_backend($1::int)', r.pid);
    console.log('terminated=' + r.pid);
  }
  const m = await c.$queryRawUnsafe('SELECT count(*)::int AS n FROM _prisma_migrations');
  console.log('applied_migrations=' + m[0].n);
  await c.$disconnect();
})().catch((e) => { console.log('ERROR ' + e.message); process.exit(1); });
'@
$tmpJs = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend\unlock-temp.js'
Set-Content -Path $tmpJs -Value $kill -Encoding UTF8
$env:DATABASE_URL = $url

Push-Location 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
try {
  # Must run with cwd = backend: node resolves `pg` from the script's directory,
  # and a script in %TEMP% cannot see backend/node_modules.
  $lines += (& node.exe $tmpJs 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally {
  Pop-Location
  $env:DATABASE_URL = $null
  Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
}

Set-Content $done -Value $lines -Encoding UTF8
Write-Output 'done'
