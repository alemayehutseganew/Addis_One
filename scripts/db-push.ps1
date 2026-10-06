param([switch]$AcceptDataLoss)

# Applies schema.prisma to the database without a migration file.
#
# Why not `migrate dev`: it is interactive and aborts with
# "the environment is non-interactive, which is not supported". In an automated
# session there is nobody to answer its prompt, so it can never be used here.
#
# Trade-off, stated plainly: `db push` does NOT write a migration file, so
# `_prisma_migrations` falls behind schema.prisma and a later `migrate deploy`
# against a fresh database would build a different schema than this one. For
# production, migrations must be authored and reviewed as SQL and applied with
# `migrate deploy`. This script is a development convenience only.

$ErrorActionPreference = 'Continue'
$backend = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out     = "$env:TEMP\addis_dbpush.txt"

# Machine-level DATABASE_URL for an unrelated project overrides .env here.
$env:DATABASE_URL = $null

$lines = @("=== db push @ $(Get-Date -Format o) ===")
Push-Location $backend
try {
  $a = @('db', 'push', '--schema', 'prisma/schema.prisma')
  if ($AcceptDataLoss) { $a += '--accept-data-loss' }
  # db push is non-interactive, so no stdin redirection is needed.
  $lines += ($a | & npx.cmd prisma @a 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally {
  Pop-Location
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output 'done'
