# Wrapper for all Prisma CLI calls.
#
# Why this exists: this machine defines a machine-level DATABASE_URL for an
# unrelated project (`bank_reviews`, using a `postgresql+psycopg2` scheme).
# OS-level env vars win over .env in child processes, so Prisma rejects the
# schema with "the URL must start with postgresql://". Clearing the inherited
# variable lets this project's .env govern, which is what we want.
#
# Usage:
#   .\scripts\run-prisma.ps1 validate
#   .\scripts\run-prisma.ps1 migrate-dev --name init
#   .\scripts\run-prisma.ps1 generate

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Command,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Continue'
$backend = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out = "$env:TEMP\addis_prisma_out.txt"

$env:DATABASE_URL = $null

$lines = @()
$lines += "=== prisma $Command $($Rest -join ' ') @ $(Get-Date -Format o) ==="

Push-Location $backend
try {
  $all = @($Command) + $Rest + @('--schema', 'prisma/schema.prisma')
  # `migrate dev` is interactive. With no console attached it can block on a
  # prompt and the process is eventually killed, leaving a stale advisory lock
  # and no migration — which then reports as P1002, looking like a dead database.
  # Redirecting from an empty stream lets it take the default (apply) and finish.
  $text = ($all | & npx.cmd prisma @all 2>&1 | Out-String)
  $lines += $text
  $lines += "exit=$LASTEXITCODE"
} finally {
  Pop-Location
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"
