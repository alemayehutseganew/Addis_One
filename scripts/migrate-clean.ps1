param([Parameter(Mandatory = $true)][string]$Name)

$ErrorActionPreference = 'Continue'
$root    = 'c:\Users\alexo\Desktop\File\Code\AddisTransport'
$backend = Join-Path $root 'backend'
$lock    = Join-Path $backend 'migrate-temp.js'
$out     = "$env:TEMP\addis_migrate.txt"

$env:DATABASE_URL = $null
$lines = @("=== migrate $Name @ $(Get-Date -Format o) ===")

# ── 1. Stop the API server and any orphaned Prisma CLI ──────────────────────
# Prisma's migrate holds a session-level advisory lock for the whole run. A
# previous attempt killed mid-migration leaves the lock held, and the next run
# then fails P1002 after 10s — which reads as "the database is down" when the
# database is actually healthy and simply locked by a zombie.
$pidFile = Join-Path $backend 'server.pid'
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
    $lines += "stopped server pid=$old"
  }
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'prisma|migrate' } |
  ForEach-Object {
    $lines += "killed prisma pid=$($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
Start-Sleep -Seconds 2

# ── 2. Clear any advisory lock still held on the database ──────────────────
# Terminating the client above releases its own locks; this catches a session
# that outlived it. pg_terminate_backend has no bigint overload, so the cast to
# int is required (otherwise Postgres rejects the call with 42883).
$unlock = @'
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
    await c.$executeRawUnsafe('SELECT pg_terminate_backend($1::int)', r.pid);
    console.log('terminated=' + r.pid);
  }
  await c.$disconnect();
})().catch((e) => { console.log('ERROR ' + e.message); });
'@
Set-Content -Path $lock -Value $unlock -Encoding UTF8
Push-Location $backend
try {
  $lines += (& node.exe $lock 2>&1 | Out-String)
} finally {
  Pop-Location
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

# ── 3. Migrate ─────────────────────────────────────────────────────────────
# `migrate dev` is interactive. With no console it can block on a prompt and be
# killed, producing the same stale-lock situation this script exists to undo.
# Feeding an empty stdin lets it take the default (apply) and exit cleanly.
Push-Location $backend
try {
  $args = @('migrate', 'dev', '--name', $Name, '--schema', 'prisma/schema.prisma')
  $text = ($args | & npx.cmd prisma @args 2>&1 | Out-String)
  $lines += $text
  $lines += "exit=$LASTEXITCODE"
} finally {
  Pop-Location
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output 'done'
